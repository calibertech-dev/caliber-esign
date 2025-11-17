public with sharing class SignatureApiClient {

    // ============================================================
    // Logging constants
    // ============================================================
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] SignatureAPI Client';
    private static final String LOG_SOURCE         = 'APEX';
    private static final String LOG_COMPONENT      = 'SignatureApiClient';

    private static void logError(
        String contextDetail,
        String message,
        Exception ex,
        String operation,
        String correlationId,
        String payloadJson
    ) {
        String fullContext = LOG_CONTEXT_PREFIX;
        if (!String.isBlank(contextDetail)) {
            fullContext += ' - ' + contextDetail;
        }

        try {
            ErrorLogService.log(
                fullContext,          // Context__c
                message,              // Message__c
                'ERROR',              // Severity__c
                correlationId,        // Correlation_Id__c
                ex,
                payloadJson,
                LOG_SOURCE,           // Source__c = APEX
                LOG_COMPONENT,        // Component__c = SignatureApiClient
                operation,            // Operation__c
                null,                 // parent record id (not known here)
                null                  // parent record type
            );
        } catch (Exception ignore) {}
    }

    // ============================================================
    // Response Classes
    // ============================================================
    public class EnvelopeCreateResponse {
        public String id;
        public String status;
        public List<RecipientInfo> recipients;
    }

    public class RecipientInfo {
        public String id;
        public String key;
        public String status;
        public String ceremonyUrl;
        public String email;
        public String name;
    }

    // ============================================================
    // HTTP Request Builder
    // ============================================================
    private static HttpRequest buildRequest(String method, String path, String bodyJson) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:SignatureApi' + path);
            req.setMethod(method);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            if (bodyJson != null) {
                req.setBody(bodyJson);
            }
            return req;
        } catch (Exception ex) {
            logError(
                'buildRequest for path ' + path,
                ex.getMessage(),
                ex,
                'buildRequest',
                null,
                JSON.serialize(new Map<String,Object>{
                    'method' => method,
                    'path'   => path,
                    'body'   => bodyJson
                })
            );
            throw ex;
        }
    }

    // ============================================================
    // HTTP Send Wrapper
    // ============================================================
    private static HttpResponse send(HttpRequest req) {
        String endpoint = req.getEndpoint();
        String requestBody = req.getBody();

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);

            Integer statusCode = res.getStatusCode();
            if (statusCode < 200 || statusCode >= 300) {
                // Log BEFORE throwing
                logError(
                    'send() failed to ' + endpoint,
                    'Non-2xx response from SignatureAPI',
                    null,
                    'send',
                    null,
                    JSON.serialize(new Map<String,Object>{
                        'endpoint'        => endpoint,
                        'statusCode'      => statusCode,
                        'responseStatus'  => res.getStatus(),
                        'responseBody'    => res.getBody(),
                        'requestBody'     => requestBody
                    })
                );

                throw new CalloutException(
                    'SignatureApi call failed: ' + statusCode + ' ' + res.getStatus() +
                    ' Body: ' + res.getBody()
                );
            }
            return res;

        } catch (Exception ex) {
            logError(
                'Exception in send() to ' + endpoint,
                ex.getMessage(),
                ex,
                'send',
                null,
                JSON.serialize(new Map<String,Object>{
                    'endpoint'    => endpoint,
                    'requestBody' => requestBody
                })
            );
            throw ex;
        }
    }

    // ============================================================
    // Create Envelope
    // ============================================================
    public static EnvelopeCreateResponse createEnvelope(Map<String, Object> payload) {
        String requestBody = JSON.serialize(payload);

        try {
            HttpRequest req = buildRequest('POST', '/v1/envelopes', requestBody);
            HttpResponse res = send(req);

            Map<String, Object> parsed =
                (Map<String, Object>)JSON.deserializeUntyped(res.getBody());

            EnvelopeCreateResponse out = new EnvelopeCreateResponse();
            out.id     = (String)parsed.get('id');
            out.status = (String)parsed.get('status');

            // Parse recipients
            List<Object> resRecipients = (List<Object>)parsed.get('recipients');
            out.recipients = new List<RecipientInfo>();
            if (resRecipients != null) {
                for (Object o : resRecipients) {
                    Map<String, Object> r = (Map<String, Object>)o;

                    RecipientInfo info = new RecipientInfo();
                    info.id          = (String)r.get('id');
                    info.key         = (String)r.get('key');
                    info.status      = (String)r.get('status');
                    info.ceremonyUrl =
                        (String)(r.containsKey('url') ? r.get('url') : r.get('ceremony_url'));
                    info.email       = (String)r.get('email');
                    info.name        = (String)r.get('name');

                    out.recipients.add(info);
                }
            }

            return out;

        } catch (Exception ex) {
            logError(
                'createEnvelope() failed',
                ex.getMessage(),
                ex,
                'createEnvelope',
                null,  // correlationId (unknown at envelope creation time)
                JSON.serialize(payload)
            );

            throw ex;
        }
    }
}
