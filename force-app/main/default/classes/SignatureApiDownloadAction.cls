public with sharing class SignatureApiDownloadAction {

    public class DownloadRequest {
        @InvocableVariable(
            label='Envelope Id'
            required=true
            description='SignatureApi envelope id (not the Salesforce Envelope__c Id).'
        )
        public String envelopeId;

        @InvocableVariable(
            label='File Name'
            required=true
            description='Base file name (without .pdf) for the downloaded document.'
        )
        public String fileName;

        @InvocableVariable(
            label='Parent Record Id'
            required=true
            description='Salesforce record that should own the downloaded file.'
        )
        public Id parentRecordId;
    }

    public class DownloadResponse {
        @InvocableVariable(
            label='Content Version Id'
            description='Id of the created ContentVersion record.'
        )
        public Id contentVersionId;

        @InvocableVariable(
            label='Error'
            description='Any error that occurred during download or file creation.'
        )
        public String error;
    }

    // ------------------------------------------------------------------
    // Logging conventions for Caliber eSign
    // ------------------------------------------------------------------
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] Download Completed Envelope PDF';
    private static final String LOG_SOURCE         = 'FLOW'; // Because this is an invocable
    private static final String LOG_COMPONENT      = 'SignatureApiDownloadAction';

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
                fullContext,
                message,
                severity,
                correlationId,
                ex,
                payloadJson,
                LOG_SOURCE,
                LOG_COMPONENT,
                operation,
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignore) {
            // Logging should never cause failures
        }
    }

    @InvocableMethod(
        label='SignatureApi - Download Completed Envelope PDF'
        description='Downloads the completed envelope PDF from SignatureApi and attaches it as a ContentVersion to the specified Salesforce record.'
    )
    public static List<DownloadResponse> downloadCompleted(List<DownloadRequest> reqs) {
        List<DownloadResponse> results = new List<DownloadResponse>();

        for (DownloadRequest req : reqs) {
            DownloadResponse resp = new DownloadResponse();

            // Values used for logging context  
            String correlationId = req != null ? req.envelopeId : null;
            Id parentRecordId    = req != null ? req.parentRecordId : null;
            String parentType    = null;

            if (parentRecordId != null) {
                try {
                    parentType = parentRecordId.getSObjectType().getDescribe().getName();
                } catch (Exception ignore) {}
            }

            try {
                // Null safeguard
                if (req == null) {
                    resp.error = 'Request is null.';

                    logEvent(
                        'Null Request',
                        resp.error,
                        'WARN',
                        null,
                        'downloadCompleted',
                        correlationId,
                        parentRecordId,
                        parentType,
                        null
                    );

                    results.add(resp);
                    continue;
                }

                // Call into the underlying download service
                SignatureApiDownloadService.DownloadResult serviceRes =
                    SignatureApiDownloadService.downloadFinalDeliverable(
                        req.envelopeId,
                        req.parentRecordId,
                        req.fileName
                    );

                resp.contentVersionId = serviceRes.contentVersionId;
                resp.error            = serviceRes.error;

                // If the service returned an error, log it
                if (serviceRes.error != null) {
                    logEvent(
                        'Service Error for Envelope ' + req.envelopeId,
                        serviceRes.error,
                        'ERROR',
                        null,
                        'downloadCompleted',
                        correlationId,
                        parentRecordId,
                        parentType,
                        JSON.serialize(new Map<String, Object>{
                            'envelopeId'       => req.envelopeId,
                            'fileName'         => req.fileName,
                            'parentRecordId'   => req.parentRecordId,
                            'serviceResult'    => serviceRes
                        })
                    );
                }

            } catch (Exception ex) {
                resp.error = ex.getMessage();

                logEvent(
                    'Unhandled Exception for Envelope ' + String.valueOf(req != null ? req.envelopeId : null),
                    ex.getMessage(),
                    'ERROR',
                    ex,
                    'downloadCompleted',
                    correlationId,
                    parentRecordId,
                    parentType,
                    (req != null)
                        ? JSON.serialize(req)
                        : null
                );
            }

            results.add(resp);
        }

        return results;
    }
}
