public with sharing class SignatureApiCreateCeremonyAction {

    // ============================================================
    // Logging constants for this invocable
    // ============================================================
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] Create Ceremony (Flow)';
    private static final String LOG_SOURCE         = 'FLOW';
    private static final String LOG_COMPONENT      = 'SignatureApiCreateCeremonyAction';

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
                severity,         // Severity__c (WARN, ERROR, etc.)
                correlationId,    // Correlation_Id__c
                ex,
                payloadJson,
                LOG_SOURCE,       // Source__c
                LOG_COMPONENT,    // Component__c
                operation,        // Operation__c
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignore) {
            // Never break the Flow because logging failed
        }
    }

    // ============================================================
    // Invocable input/output classes
    // ============================================================
    public class CeremonyRequest {
        @InvocableVariable(required=true)
        public Id envelopeRecipientId;
    }

    public class CeremonyResponse {
        @InvocableVariable public Id envelopeRecipientId;
        @InvocableVariable public String ceremonyUrl;
        @InvocableVariable public String error;
    }

    // ============================================================
    // Invocable entry point
    // ============================================================
    @InvocableMethod(
        label='SignatureApi - Create Ceremony for Recipient'
        description='Creates a SignatureApi ceremony for a given Envelope_Recipient__c and stores the URL.'
    )
    public static List<CeremonyResponse> createCeremonies(List<CeremonyRequest> requests) {
        List<CeremonyResponse> out = new List<CeremonyResponse>();

        for (CeremonyRequest req : requests) {
            CeremonyResponse resp = new CeremonyResponse();
            resp.envelopeRecipientId = req.envelopeRecipientId;

            Id parentRecordId      = null;
            String parentRecordType = null;
            String correlationId     = null;

            try {
                // ===================================================
                // Resolve envelope + parent record for correlation
                // ===================================================
                Envelope_Recipient__c rec = [
                    SELECT Id,
                           Envelope__c,
                           Envelope__r.Envelope_Id__c,
                           Envelope__r.Parent_Record_Id__c,
                           Envelope__r.Parent_Record_Type__c
                    FROM Envelope_Recipient__c
                    WHERE Id = :req.envelopeRecipientId
                ];

                if (rec.Envelope__r != null) {
                    correlationId = rec.Envelope__r.Envelope_Id__c;

                    if (rec.Envelope__r.Parent_Record_Id__c != null) {
                        parentRecordId   = (Id)rec.Envelope__r.Parent_Record_Id__c;
                        parentRecordType = rec.Envelope__r.Parent_Record_Type__c;
                    } else {
                        parentRecordId   = rec.Envelope__c;
                        parentRecordType = 'Envelope__c';
                    }
                } else {
                    // Fallback if envelope lookup missing
                    correlationId     = String.valueOf(req.envelopeRecipientId);
                    parentRecordId    = req.envelopeRecipientId;
                    parentRecordType  = 'Envelope_Recipient__c';
                }

                // ===================================================
                // Call the ceremony creation service
                // ===================================================
                SignatureApiCeremonyService.CeremonyResult serviceRes =
                    SignatureApiCeremonyService.createCeremonyForRecipient(req.envelopeRecipientId);

                resp.ceremonyUrl = serviceRes.ceremonyUrl;
                resp.error       = serviceRes.error;

                // Log WARN when service returns an error but no exception occurred
                if (serviceRes.error != null) {
                    String payloadJson = JSON.serialize(new Map<String, Object>{
                        'envelopeRecipientId' => req.envelopeRecipientId,
                        'ceremonyUrl'         => serviceRes.ceremonyUrl,
                        'error'               => serviceRes.error
                    });

                    logEvent(
                        'Service returned an error',
                        serviceRes.error,
                        'WARN',
                        null,
                        'createCeremonies',
                        correlationId,
                        parentRecordId,
                        parentRecordType,
                        payloadJson
                    );
                }

            } catch (Exception ex) {
                resp.error = ex.getMessage();

                String payloadJson = JSON.serialize(new Map<String, Object>{
                    'envelopeRecipientId' => req.envelopeRecipientId
                });

                logEvent(
                    'Unhandled exception creating ceremony',
                    ex.getMessage(),
                    'ERROR',
                    ex,
                    'createCeremonies',
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    payloadJson
                );
            }

            out.add(resp);
        }

        return out;
    }
}
