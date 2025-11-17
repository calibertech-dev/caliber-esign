public with sharing class SignatureApiCeremonyService {

    public class CeremonyResult {
        public Id envelopeRecipientId;
        public String ceremonyUrl;
        public String error;
    }

    // ------------------------------------------------------------------
    // Logging configuration
    // ------------------------------------------------------------------
    // Context__c is a long text area – we use it to encode package + scenario.
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] SignatureAPI Ceremony';
    // Source__c is a picklist (APEX/FLOW/TRIGGER/etc.)
    private static final String LOG_SOURCE         = 'APEX';
    // Component__c = technical component name (class / handler / flow)
    private static final String LOG_COMPONENT      = 'SignatureApiCeremonyService';

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
                LOG_SOURCE,       // Source__c (APEX/FLOW/...)
                LOG_COMPONENT,    // Component__c
                operation,        // Operation__c
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignore) {
            // Logging must never break business logic
        }
    }

    /**
     * Core method: create a ceremony for a single Envelope_Recipient__c.
     * Expects Envelope_Recipient__c.Recipient_Id__c to be populated
     * from the envelope creation response.
     */
    public static CeremonyResult createCeremonyForRecipient(Id envelopeRecipientId) {
        CeremonyResult res = new CeremonyResult();
        res.envelopeRecipientId = envelopeRecipientId;

        // Common correlation/parent context, filled once we fetch the recipient
        String correlationId;
        Id parentRecordId;
        String parentRecordType;

        // Track request info so we can log it if things go sideways
        String endpoint;
        String requestBody;

        try {
            // Load recipient + parent envelope
            Envelope_Recipient__c rec = [
                SELECT Id,
                       Envelope__c,
                       Recipient_Id__c,
                       Ceremony_URL__c,
                       Envelope__r.Envelope_Id__c,
                       Envelope__r.Parent_Record_Id__c,
                       Envelope__r.Parent_Record_Type__c
                FROM Envelope_Recipient__c
                WHERE Id = :envelopeRecipientId
            ];

            // Establish correlation + parent context
            correlationId = (rec.Envelope__r != null && !String.isBlank(rec.Envelope__r.Envelope_Id__c))
                ? rec.Envelope__r.Envelope_Id__c
                : String.valueOf(rec.Envelope__c);

            if (rec.Envelope__r != null && rec.Envelope__r.Parent_Record_Id__c != null) {
                parentRecordId   = (Id)rec.Envelope__r.Parent_Record_Id__c;
                parentRecordType = rec.Envelope__r.Parent_Record_Type__c;
            } else {
                parentRecordId   = rec.Envelope__c;
                parentRecordType = 'Envelope__c';
            }

            if (String.isBlank(rec.Recipient_Id__c)) {
                res.error = 'SignatureApi recipient id is missing on Envelope_Recipient__c.';

                // Data/config issue: WARN
                logEvent(
                    'Missing recipient id on Envelope_Recipient__c ' + rec.Id,
                    res.error,
                    'WARN',
                    null,
                    'createCeremonyForRecipient',
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(new Map<String, Object>{
                        'envelopeRecipientId' => rec.Id
                    })
                );

                return res;
            }

            String recipientExternalId = rec.Recipient_Id__c;

            // Build endpoint: /v1/recipients/{id}/ceremony using Named Credential
            endpoint = 'callout:SignatureApi'
                     + '/v1/recipients/'
                     + EncodingUtil.urlEncode(recipientExternalId, 'UTF-8')
                     + '/ceremony';

            // Custom auth payload
            Map<String, Object> authBlock = new Map<String, Object>{
                'type'     => 'custom',
                'provider' => 'Salesforce',
                'data'     => new Map<String, Object>{
                    'requested_at' => String.valueOf(Datetime.now().getTime()),
                    'requested_by' => String.valueOf(UserInfo.getUserId())
                }
            };

            Map<String, Object> payload = new Map<String, Object>{
                'authentication' => new List<Object>{ authBlock }
            };

            Http http = new Http();
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');

            requestBody = JSON.serialize(payload);
            req.setBody(requestBody);

            HttpResponse h = http.send(req);

            if (h.getStatusCode() >= 200 && h.getStatusCode() < 300) {
                Map<String, Object> body =
                    (Map<String, Object>)JSON.deserializeUntyped(h.getBody());
                String url = (String)body.get('url');

                if (String.isBlank(url)) {
                    res.error = 'Ceremony created but no URL returned from SignatureApi.';

                    logEvent(
                        'Empty URL returned from ceremony creation for Envelope_Recipient__c ' + rec.Id,
                        res.error,
                        'ERROR',
                        null,
                        'createCeremonyForRecipient',
                        correlationId,
                        parentRecordId,
                        parentRecordType,
                        JSON.serialize(new Map<String, Object>{
                            'endpoint'            => endpoint,
                            'statusCode'          => h.getStatusCode(),
                            'responseBody'        => h.getBody(),
                            'envelopeRecipientId' => rec.Id
                        })
                    );

                    return res;
                }

                // Persist URL on the recipient
                rec.Ceremony_URL__c = url;
                update rec;

                res.ceremonyUrl = url;
                return res;

            } else {
                res.error = 'Ceremony creation failed: ' +
                            h.getStatusCode() + ' ' + h.getBody();

                logEvent(
                    'HTTP error from SignatureAPI ceremony endpoint for Envelope_Recipient__c ' + rec.Id,
                    res.error,
                    'ERROR',
                    null,
                    'createCeremonyForRecipient',
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    JSON.serialize(new Map<String, Object>{
                        'endpoint'            => endpoint,
                        'statusCode'          => h.getStatusCode(),
                        'responseBody'        => h.getBody(),
                        'requestBody'         => requestBody,
                        'envelopeRecipientId' => rec.Id
                    })
                );

                return res;
            }

        } catch (Exception e) {
            res.error = e.getMessage();

            logEvent(
                'Unhandled exception creating ceremony for Envelope_Recipient__c ' + String.valueOf(envelopeRecipientId),
                res.error,
                'ERROR',
                e,
                'createCeremonyForRecipient',
                correlationId,
                parentRecordId,
                parentRecordType,
                JSON.serialize(new Map<String, Object>{
                    'endpoint'            => endpoint,
                    'requestBody'         => requestBody,
                    'envelopeRecipientId' => envelopeRecipientId
                })
            );

            return res;
        }
    }
}
