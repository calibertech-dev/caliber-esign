public with sharing class SignatureApiNotificationService {

    // ------------------------------------------------------------------
    // Logging Configuration
    // ------------------------------------------------------------------
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] Notification Service';
    private static final String LOG_SOURCE         = 'APEX';
    private static final String LOG_COMPONENT      = 'SignatureApiNotificationService';
    private static final String LOG_OPERATION      = 'handlePostCreateNotifications';

    private static void logEvent(
        String contextDetail,
        String message,
        String severity,
        Exception ex,
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
                fullContext,
                message,
                severity,
                correlationId,
                ex,
                payloadJson,
                LOG_SOURCE,
                LOG_COMPONENT,
                LOG_OPERATION,
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignored) {
            // Never allow logging failures to break functional code
        }
    }

    /**
     * Called after a successful envelope create.
     * - Fetches Envelope__c → Parent → Document_Template__c → Envelope_Template__c
     * - Uses Signing_Request_Email_Template__c
     * - Sends emails to recipients whose Ceremony_URL__c is populated
     *   (manual ceremony mode only).
     */
    public static void handlePostCreateNotifications(Id envelopeId) {

        String correlationId = null;
        Id parentRecordId    = null;
        String parentRecordType = null;

        try {
            Envelope__c env = [
                SELECT Id,
                       Envelope_Id__c,
                       Parent_Record_Type__c,
                       Parent_Record_Id__c
                FROM Envelope__c
                WHERE Id = :envelopeId
            ];

            correlationId    = env.Envelope_Id__c;
            parentRecordId   = (Id)env.Parent_Record_Id__c;
            parentRecordType = env.Parent_Record_Type__c;

            SObject parent = SignatureApiEnvelopeOrchestrationService.loadParent(
                env.Parent_Record_Id__c,
                env.Parent_Record_Type__c
            );

            Id documentTemplateId = (Id)parent.get('Document_Template__c');
            if (documentTemplateId == null) {
                logEvent(
                    'Missing Document Template',
                    'Parent record has no Document_Template__c; cannot send signing request emails.',
                    'WARN',
                    null,
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(new Map<String,Object>{
                        'envelopeId'      => env.Id,
                        'parentRecordId'  => parentRecordId
                    })
                );
                return;
            }

            Document_Template__c docTmpl = [
                SELECT Id, Envelope_Template__c
                FROM Document_Template__c
                WHERE Id = :documentTemplateId
            ];

            if (docTmpl.Envelope_Template__c == null) {
                logEvent(
                    'Missing Envelope Template',
                    'Document Template has no Envelope_Template__c; cannot send signing request emails.',
                    'WARN',
                    null,
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(docTmpl)
                );
                return;
            }

            Envelope_Template__c eTemplate = [
                SELECT Id,
                       Signing_Request_Email_Template__c,
                       Ceremony_Creation__c
                FROM Envelope_Template__c
                WHERE Id = :docTmpl.Envelope_Template__c
            ];

            if (eTemplate.Ceremony_Creation__c == 'automatic') {
                logEvent(
                    'Automatic ceremony mode',
                    'Ceremony creation is automatic; skipping signing request emails.',
                    'INFO',
                    null,
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(eTemplate)
                );
                return;
            }

            if (String.isBlank(eTemplate.Signing_Request_Email_Template__c)) {
                logEvent(
                    'Missing Email Template',
                    'Envelope Template has no Signing_Request_Email_Template__c; skipping notifications.',
                    'WARN',
                    null,
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(eTemplate)
                );
                return;
            }

            Id emailTemplateId = (Id)eTemplate.Signing_Request_Email_Template__c;

            List<Envelope_Recipient__c> recs = [
                SELECT Id,
                       Name,
                       Recipient_Email__c,
                       Recipient_Key__c,
                       Ceremony_URL__c,
                       Status__c
                FROM Envelope_Recipient__c
                WHERE Envelope__c = :env.Id
            ];

            if (recs.isEmpty()) {
                logEvent(
                    'No Recipients Found',
                    'Envelope has no Envelope_Recipient__c records; no notifications sent.',
                    'WARN',
                    null,
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    null
                );
                return;
            }

            List<EmailService.EmailRequest> emailRequests = new List<EmailService.EmailRequest>();

            for (Envelope_Recipient__c r : recs) {
                // Only send if we have both email and ceremony URL
                if (String.isBlank(r.Recipient_Email__c) || String.isBlank(r.Ceremony_URL__c)) {
                    continue;
                }

                EmailService.EmailRequest er = new EmailService.EmailRequest();
                er.templateId   = emailTemplateId;
                er.whatId       = parent.Id;
                er.whoId        = null; // We don't have a Contact/Lead here; using direct email
                er.toAddresses  = new List<String>{ r.Recipient_Email__c };
                er.saveAsActivity = true;

                emailRequests.add(er);
            }

            if (emailRequests.isEmpty()) {
                logEvent(
                    'No Sendable Recipients',
                    'All recipients were missing email or ceremony URL; no notifications sent.',
                    'WARN',
                    null,
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    null
                );
                return;
            }

            // Delegate the actual send to EmailService in Caliber Core
            EmailService.EmailResult sendResult = EmailService.send(
                emailRequests,
                'Envelope__c ' + env.Id + ' - Signing Request Notifications',
                correlationId,
                parentRecordId,
                parentRecordType
            );

            // Optional: log summary at this level too, if you want double visibility
            logEvent(
                'Emails Sent',
                'Sent ' + sendResult.sentEmails + ' signing request email(s).',
                'INFO',
                null,
                correlationId,
                parentRecordId,
                parentRecordType,
                JSON.serialize(new Map<String,Object>{
                    'totalRequests' => sendResult.totalRequests,
                    'builtEmails'   => sendResult.builtEmails,
                    'sentEmails'    => sendResult.sentEmails
                })
            );

        } catch (Exception ex) {
            logEvent(
                'Unhandled Exception',
                'Exception sending post-create notifications: ' + ex.getMessage(),
                'ERROR',
                ex,
                correlationId,
                parentRecordId,
                parentRecordType,
                JSON.serialize(new Map<String,Object>{
                    'envelopeId' => envelopeId
                })
            );
            throw ex;
        }
    }
}
