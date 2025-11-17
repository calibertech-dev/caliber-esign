public with sharing class SignatureApiWebhookProcessor implements Queueable, Database.AllowsCallouts {

    // ==========================================================
    // Logging configuration
    // ==========================================================
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] SignatureAPI Webhook';
    private static final String LOG_SOURCE         = 'APEX';
    private static final String LOG_COMPONENT      = 'SignatureApiWebhookProcessor';

    private Id envelopeEventId;

    public SignatureApiWebhookProcessor(Id envelopeEventId) {
        this.envelopeEventId = envelopeEventId;
    }

    /**
     * Central logging helper. Fields mapping:
     * - Context__c   = "[Caliber eSign] SignatureAPI Webhook - <contextDetail>"
     * - Source__c    = "APEX"
     * - Component__c = "SignatureApiWebhookProcessor"
     * - Operation__c = operation
     */
    private static void logEvent(
        String contextDetail,
        String message,
        String severity,
        Exception ex,
        String operation,
        String correlationId,
        Id parentRecordId,
        String parentRecordType,
        String payloadJson
    ) {
        String fullContext = LOG_CONTEXT_PREFIX;
        if (!String.isBlank(contextDetail)) {
            fullContext += ' - ' + contextDetail;
        }

        try {
            ErrorLogService.log(
                fullContext,      // Context__c
                message,          // Message__c
                severity,         // Severity__c
                correlationId,    // Correlation_Id__c
                ex,
                payloadJson,      // Payload__c
                LOG_SOURCE,       // Source__c
                LOG_COMPONENT,    // Component__c
                operation,        // Operation__c
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignore) {
            // Logging must never break the main flow
        }
    }

    public void execute(QueueableContext qc) {
        if (envelopeEventId == null) {
            return;
        }

        Envelope_Event__c evt = [
            SELECT Id,
                   Event_Type__c,
                   Envelope_Id__c,
                   Object_Id__c,
                   Recipient_Key__c,
                   Status__c,
                   Raw_Payload__c,
                   Processing_Status__c,
                   Error_Message__c
            FROM Envelope_Event__c
            WHERE Id = :envelopeEventId
        ];

        String correlationId = evt.Envelope_Id__c;
        Id parentRecordId;
        String parentRecordType;

        try {
            evt.Processing_Status__c = 'Processing';
            update evt;

            String eventType = evt.Event_Type__c;

            // ---- Envelope-level events ----
            if (eventType == 'envelope.completed') {
                handleEnvelopeCompleted(evt);
            } else if (eventType == 'envelope.canceled') {
                handleEnvelopeCanceled(evt);
            } else if (eventType == 'envelope.failed') {
                handleEnvelopeFailed(evt);
            } else if (eventType == 'envelope.started') {
                handleEnvelopeStarted(evt);
            } else if (eventType == 'envelope.created') {
                handleEnvelopeCreated(evt);
            }

            // ---- Recipient-level events ----
            else if (eventType == 'recipient.completed') {
                handleRecipientCompleted(evt);
            } else if (eventType == 'recipient.rejected') {
                handleRecipientRejected(evt);
            } else if (eventType == 'recipient.released') {
                handleRecipientReleased(evt);
            } else if (eventType == 'recipient.failed') {
                handleRecipientFailed(evt);
            } else if (eventType == 'recipient.sent' || eventType == 'recipient.resent') {
                handleRecipientSent(evt);
            } else if (eventType == 'recipient.replaced') {
                handleRecipientReplaced(evt);
            } else if (eventType == 'recipient.hard_bounced' ||
                       eventType == 'recipient.soft_bounced') {
                handleRecipientBounced(evt);
            }

            // ---- Deliverable-level events ----
            else if (eventType == 'deliverable.generated') {
                handleDeliverableGenerated(evt);
            } else if (eventType == 'deliverable.failed') {
                handleDeliverableFailed(evt);
            }

            // ---- Sender-level events ----
            else if (eventType == 'sender.created') {
                handleSenderCreated(evt);
            } else if (eventType == 'sender.deleted') {
                handleSenderDeleted(evt);
            } else if (eventType == 'sender.failed') {
                handleSenderFailed(evt);
            } else if (eventType == 'sender.verified') {
                handleSenderVerified(evt);
            }

            evt.Processing_Status__c = 'Completed';
            evt.Error_Message__c     = null;
            update evt;

        } catch (Exception ex) {
            evt.Processing_Status__c = 'Failed';
            evt.Error_Message__c     = ex.getMessage();
            update evt;

            // Best-effort link to the parent record (Envelope or parent of Envelope)
            try {
                // Try to locate the envelope to hang the log off a business record if possible
                List<Envelope__c> envs = [
                    SELECT Id, Envelope_Id__c, Parent_Record_Id__c, Parent_Record_Type__c
                    FROM Envelope__c
                    WHERE Envelope_Id__c = :evt.Envelope_Id__c
                    LIMIT 1
                ];
                if (!envs.isEmpty()) {
                    Envelope__c env = envs[0];
                    if (env.Parent_Record_Id__c != null) {
                        parentRecordId   = (Id)env.Parent_Record_Id__c;
                        parentRecordType = env.Parent_Record_Type__c;
                    } else {
                        parentRecordId   = env.Id;
                        parentRecordType = 'Envelope__c';
                    }
                }
            } catch (Exception ignoreEnv) {
                // If this fails, we'll fall back to logging against the event itself
            }

            if (parentRecordId == null) {
                parentRecordId   = evt.Id;
                parentRecordType = 'Envelope_Event__c';
            }

            logEvent(
                'Webhook ' + evt.Id + ' eventType=' + evt.Event_Type__c,
                'Webhook processing failed for Envelope_Event__c ' + evt.Id,
                'ERROR',
                ex,
                'execute',
                correlationId,
                parentRecordId,
                parentRecordType,
                evt.Raw_Payload__c
            );
        }
    }

    // ===========================
    // Envelope handlers
    // ===========================

    private static void handleEnvelopeCompleted(Envelope_Event__c evt) {
        List<Envelope__c> envs = [
            SELECT Id, Name, Envelope_Id__c, Parent_Record_Id__c, Status__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];
        if (envs.isEmpty()) return;

        Envelope__c env = envs[0];
        env.Status__c = 'Completed';   // valid value for Envelope__c.Status__c
        update env;
    }

    private static void handleEnvelopeCanceled(Envelope_Event__c evt) {
        List<Envelope__c> envs = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];
        if (envs.isEmpty()) return;

        Envelope__c env = envs[0];
        env.Status__c = 'Canceled';
        update env;
    }

    private static void handleEnvelopeFailed(Envelope_Event__c evt) {
        List<Envelope__c> envs = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];
        if (envs.isEmpty()) return;

        Envelope__c env = envs[0];
        env.Status__c = 'Failed';
        update env;
    }

    private static void handleEnvelopeStarted(Envelope_Event__c evt) {
        List<Envelope__c> envs = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];
        if (envs.isEmpty()) return;

        Envelope__c env = envs[0];
        env.Status__c = 'In Progress';
        update env;
    }

    private static void handleEnvelopeCreated(Envelope_Event__c evt) {
        List<Envelope__c> envs = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];
        if (envs.isEmpty()) return;

        Envelope__c env = envs[0];
        env.Status__c = 'Processing';
        update env;
    }

    // ===========================
    // Recipient handlers
    // ===========================

    private static void handleRecipientCompleted(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        rec.Status__c = 'Completed';
        update rec;
    }

    private static void handleRecipientRejected(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        rec.Status__c = 'Rejected';
        update rec;
    }

    private static void handleRecipientReleased(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        // your definition of "released"; Pending is valid on recipient
        rec.Status__c = 'Pending';
        update rec;
    }

    private static void handleRecipientFailed(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        rec.Status__c = 'Failed';
        update rec;
    }

    private static void handleRecipientSent(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        rec.Status__c = 'Sent';
        update rec;
    }

    private static void handleRecipientBounced(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        rec.Status__c = 'Bounced';
        update rec;
    }

    private static void handleRecipientReplaced(Envelope_Event__c evt) {
        Envelope_Recipient__c rec = findRecipient(evt);
        if (rec == null) return;

        rec.Status__c = 'Replaced';
        update rec;
    }

    // ===========================
    // Deliverable handlers
    // ===========================

    private static void handleDeliverableGenerated(Envelope_Event__c evt) {
        // Find the envelope first
        List<Envelope__c> envs = [
            SELECT Id, Name, Envelope_Id__c, Parent_Record_Id__c, Parent_Record_Type__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];
        if (envs.isEmpty()) return;

        Envelope__c env = envs[0];

        Id parentRecordId;
        String parentRecordType;
        if (env.Parent_Record_Id__c != null) {
            parentRecordId   = (Id)env.Parent_Record_Id__c;
            parentRecordType = env.Parent_Record_Type__c;
        } else {
            parentRecordId   = env.Id;
            parentRecordType = 'Envelope__c';
        }

        try {
            SignatureApiDownloadService.DownloadResult dl =
                SignatureApiDownloadService.downloadFinalDeliverableForEnvelopeRecord(
                    env,
                    env.Name
                );

            if (dl.error != null) {
                // Our download failed (Salesforce side) – log it
                logEvent(
                    'deliverable.generated download error for Envelope__c ' + env.Id,
                    'Download error for envelope ' + env.Id + ': ' + dl.error,
                    'ERROR',
                    null,
                    'handleDeliverableGenerated',
                    env.Envelope_Id__c,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(new Map<String, Object>{
                        'envelopeEventId'  => evt.Id,
                        'envelopeId'       => env.Id,
                        'signatureApiEnvelopeId' => env.Envelope_Id__c,
                        'downloadError'    => dl.error
                    })
                );
            }
        } catch (Exception e) {
            // Exception on our side while handling a successful deliverable.generated
            logEvent(
                'Exception during deliverable.generated download for Envelope__c ' + env.Id,
                'Exception during deliverable.generated download: ' + e.getMessage(),
                'ERROR',
                e,
                'handleDeliverableGenerated',
                env.Envelope_Id__c,
                parentRecordId,
                parentRecordType,
                JSON.serialize(new Map<String, Object>{
                    'envelopeEventId'  => evt.Id,
                    'envelopeId'       => env.Id,
                    'signatureApiEnvelopeId' => env.Envelope_Id__c
                })
            );
        }
    }

    private static void handleDeliverableFailed(Envelope_Event__c evt) {
        // This indicates SignatureApi had a problem generating the completed document.
        // That is an upstream failure, not a Salesforce processing failure.
        List<Envelope__c> envs = [
            SELECT Id, Name, Envelope_Id__c, Parent_Record_Id__c, Parent_Record_Type__c
            FROM Envelope__c
            WHERE Envelope_Id__c = :evt.Envelope_Id__c
            LIMIT 1
        ];

        Id parentRecordId;
        String parentRecordType;
        String correlationId = evt.Envelope_Id__c;

        if (!envs.isEmpty()) {
            Envelope__c env = envs[0];
            if (env.Parent_Record_Id__c != null) {
                parentRecordId   = (Id)env.Parent_Record_Id__c;
                parentRecordType = env.Parent_Record_Type__c;
            } else {
                parentRecordId   = env.Id;
                parentRecordType = 'Envelope__c';
            }
        } else {
            // Fall back to the event if we cannot locate the envelope
            parentRecordId   = evt.Id;
            parentRecordType = 'Envelope_Event__c';
        }

        logEvent(
            'deliverable.failed for Envelope_Id__c ' + String.valueOf(evt.Envelope_Id__c),
            'SignatureApi reported deliverable.failed for envelope ' + String.valueOf(evt.Envelope_Id__c),
            'ERROR',
            null,
            'handleDeliverableFailed',
            correlationId,
            parentRecordId,
            parentRecordType,
            evt.Raw_Payload__c
        );
    }

    // ===========================
    // Sender handlers
    // ===========================

    private static void handleSenderCreated(Envelope_Event__c evt) {
        // future behaviour
    }

    private static void handleSenderDeleted(Envelope_Event__c evt) {
        // future behavior
    }

    private static void handleSenderFailed(Envelope_Event__c evt) {
        // future behavior
    }

    private static void handleSenderVerified(Envelope_Event__c evt) {
        // future behavior
    }

    // ===========================
    // Shared helper
    // ===========================

    private static Envelope_Recipient__c findRecipient(Envelope_Event__c evt) {
        // Prefer match on external recipient id
        List<Envelope_Recipient__c> recs;

        if (!String.isBlank(evt.Object_Id__c)) {
            recs = [
                SELECT Id, Envelope__c, Recipient_Id__c, Recipient_Key__c, Status__c
                FROM Envelope_Recipient__c
                WHERE Recipient_Id__c = :evt.Object_Id__c
                LIMIT 1
            ];
            if (!recs.isEmpty()) return recs[0];
        }

        if (!String.isBlank(evt.Envelope_Id__c) && !String.isBlank(evt.Recipient_Key__c)) {
            recs = [
                SELECT Id, Envelope__c, Recipient_Id__c, Recipient_Key__c, Status__c
                FROM Envelope_Recipient__c
                WHERE Recipient_Key__c = :evt.Recipient_Key__c
                AND Envelope__r.Envelope_Id__c = :evt.Envelope_Id__c
                LIMIT 1
            ];
            if (!recs.isEmpty()) return recs[0];
        }

        return null;
    }
}
