@RestResource(urlMapping='/signatureapi/webhook')
global with sharing class SignatureApiWebhookHandler {

    // ===================================================
    // Logging Constants
    // ===================================================
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] SignatureAPI Webhook';
    private static final String LOG_SOURCE         = 'APEX';
    private static final String LOG_COMPONENT      = 'SignatureApiWebhookHandler';
    private static final String LOG_OPERATION      = 'handleWebhook';

    // ---------------------------------------------------
    // Small logging helper used only in this class
    // ---------------------------------------------------
    private static void logEvent(
        String contextDetail,
        String message,
        String severity,
        Exception ex,
        String correlationId,
        String payloadJson
    ) {
        String fullContext = LOG_CONTEXT_PREFIX;
        if (!String.isBlank(contextDetail)) {
            fullContext += ' - ' + contextDetail;
        }

        try {
            ErrorLogService.log(
                fullContext,       // Context__c (LTA)
                message,           // Message__c
                severity,          // Severity__c
                correlationId,     // Correlation_Id__c
                ex,
                payloadJson,       // Payload__c
                LOG_SOURCE,        // Source__c = APEX
                LOG_COMPONENT,     // Component__c = class name
                LOG_OPERATION,     // Operation__c = method
                null,              // parentRecordId
                null               // parentRecordType
            );
        } catch (Exception ignore) {
            // Logging must NEVER break a webhook endpoint
        }
    }


    // ===================================================
    // Webhook handler
    // ===================================================
    @HttpPost
    global static void handleWebhook() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        // Always ACK 200 so SignatureAPI will not retry forever
        res.statusCode   = 200;
        res.responseBody = Blob.valueOf('OK');

        String body = null;
        String correlationId = null;

        try {
            // -------------------------
            // Read raw body
            // -------------------------
            body = (req.requestBody != null)
                ? req.requestBody.toString()
                : '';

            if (String.isBlank(body)) {
                logEvent(
                    'Empty webhook payload',
                    'Webhook received an empty request body.',
                    'WARN',
                    null,
                    null,
                    null
                );
                return;
            }

            // -------------------------
            // Parse JSON
            // -------------------------
            Map<String, Object> payload =
                (Map<String, Object>)JSON.deserializeUntyped(body);

            String eventType = (String)payload.get('type');
            Map<String, Object> data =
                (Map<String, Object>)payload.get('data');

            String envelopeId   = data != null ? (String)data.get('envelope_id')   : null;
            String objectId     = data != null ? (String)data.get('object_id')     : null;
            String recipientKey = data != null ? (String)data.get('recipient_key') : null;
            String status       = data != null ? (String)data.get('status')        : null;

            // Correlation id for logging (SignatureAPI envelope id)
            correlationId = envelopeId;

            // -------------------------
            // Create event record
            // -------------------------
            Envelope_Event__c evt = new Envelope_Event__c();
            evt.Event_Type__c     = eventType;
            evt.Envelope_Id__c    = envelopeId;
            evt.Object_Id__c      = objectId;
            evt.Recipient_Key__c  = recipientKey;
            evt.Status__c         = status;
            evt.Raw_Payload__c    = body;
            evt.Processing_Status__c = 'Received';

            insert evt;

            // -------------------------
            // Process asynchronously
            // -------------------------
            System.enqueueJob(new SignatureApiWebhookProcessor(evt.Id));

        } catch (Exception e) {

            // Log via ErrorLogService
            logEvent(
                'Webhook processing error',
                e.getMessage(),
                'ERROR',
                e,
                correlationId,
                body
            );

            // Also fall back to creating an Envelope_Event__c (safeguard)
            try {
                Envelope_Event__c errorEvt = new Envelope_Event__c();
                errorEvt.Event_Type__c        = 'webhook.error';
                errorEvt.Raw_Payload__c       = body;
                errorEvt.Error_Message__c     = e.getMessage();
                errorEvt.Processing_Status__c = 'Failed';
                insert errorEvt;
            } catch (Exception ignore2) {
                // Last-resort debug. Should basically never occur.
            }
        }
    }
}
