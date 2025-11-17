public with sharing class SignatureApiDownloadService {

    public class DownloadResult {
        public Id contentVersionId;
        public String error;
    }

    // ================================================================
    // Logging Setup
    // ================================================================
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] SignatureAPI Download';
    private static final String LOG_SOURCE         = 'APEX';
    private static final String LOG_COMPONENT      = 'SignatureApiDownloadService';

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
        String ctx = LOG_CONTEXT_PREFIX;
        if (!String.isBlank(contextDetail)) ctx += ' – ' + contextDetail;

        try {
            ErrorLogService.log(
                ctx,
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
        } catch (Exception ignore) {}
    }

    // ================================================================
    // Main Download Logic
    // ================================================================
    public static DownloadResult downloadFinalDeliverable(
        String envelopeId,
        Id parentRecordId,
        String fileName
    ) {
        DownloadResult result = new DownloadResult();
        String operation = 'downloadFinalDeliverable';

        if (String.isBlank(envelopeId)) {
            result.error = 'Envelope Id is required.';
            logEvent(
                'Missing envelopeId',
                result.error,
                'WARN',
                null,
                operation,
                null,
                parentRecordId,
                parentRecordId != null ? parentRecordId.getSObjectType().getDescribe().getName() : null,
                null
            );
            return result;
        }
        if (parentRecordId == null) {
            result.error = 'Parent Record Id is required.';
            logEvent(
                'Missing parentRecordId',
                result.error,
                'WARN',
                null,
                operation,
                envelopeId,
                null,
                null,
                null
            );
            return result;
        }
        if (String.isBlank(fileName)) fileName = 'Signed Document';

        Http http = new Http();

        // Track callout data for payload logging
        String listEndpoint, metadataEndpoint, downloadUrl, requestBody;
        Integer status;
        try {
            // -----------------------------------------------------------
            // 1) List deliverables
            // -----------------------------------------------------------
            listEndpoint = 'callout:SignatureApi/v1/envelopes/' +
                           EncodingUtil.urlEncode(envelopeId, 'UTF-8') +
                           '/deliverables';

            HttpRequest listReq = new HttpRequest();
            listReq.setEndpoint(listEndpoint);
            listReq.setMethod('GET');

            HttpResponse listRes = http.send(listReq);
            status = listRes.getStatusCode();

            if (status >= 300) {
                result.error = 'Deliverables list failed: ' +
                               listRes.getStatus() + ' ' + listRes.getBody();

                logEvent(
                    'Listing deliverables for envelope ' + envelopeId,
                    result.error,
                    'ERROR',
                    null,
                    operation,
                    envelopeId,
                    parentRecordId,
                    parentRecordId.getSObjectType().getDescribe().getName(),
                    JSON.serialize(new Map<String, Object>{
                        'endpoint'     => listEndpoint,
                        'statusCode'   => status,
                        'body'         => listRes.getBody()
                    })
                );
                return result;
            }

            Map<String, Object> listMap =
                (Map<String, Object>)JSON.deserializeUntyped(listRes.getBody());
            List<Object> dlist = (List<Object>)listMap.get('data');

            if (dlist == null || dlist.isEmpty()) {
                result.error = 'No deliverables found for envelope ' + envelopeId;

                logEvent(
                    'Deliverables list empty',
                    result.error,
                    'WARN',
                    null,
                    operation,
                    envelopeId,
                    parentRecordId,
                    parentRecordId.getSObjectType().getDescribe().getName(),
                    listRes.getBody()
                );
                return result;
            }

            // Find sealed_document if present
            String deliverableId;
            for (Object o : dlist) {
                Map<String, Object> dm = (Map<String, Object>)o;
                if ('sealed_document'.equals(dm.get('type'))) {
                    deliverableId = (String)dm.get('id');
                    break;
                }
            }
            if (deliverableId == null) {
                deliverableId =
                    (String)((Map<String, Object>)dlist.get(0)).get('id');
            }

            // -----------------------------------------------------------
            // 2) Deliverable metadata
            // -----------------------------------------------------------
            metadataEndpoint = 'callout:SignatureApi/v1/deliverables/' +
                               EncodingUtil.urlEncode(deliverableId, 'UTF-8');

            HttpRequest metadataReq = new HttpRequest();
            metadataReq.setEndpoint(metadataEndpoint);
            metadataReq.setMethod('GET');

            HttpResponse metadataRes = http.send(metadataReq);
            status = metadataRes.getStatusCode();

            if (status >= 300) {
                result.error = 'Deliverable fetch failed: ' +
                               metadataRes.getStatus() + ' ' + metadataRes.getBody();

                logEvent(
                    'Fetching deliverable metadata ' + deliverableId,
                    result.error,
                    'ERROR',
                    null,
                    operation,
                    envelopeId,
                    parentRecordId,
                    parentRecordId.getSObjectType().getDescribe().getName(),
                    JSON.serialize(new Map<String, Object>{
                        'endpoint'     => metadataEndpoint,
                        'statusCode'   => status,
                        'body'         => metadataRes.getBody()
                    })
                );
                return result;
            }

            Map<String, Object> dmap =
                (Map<String, Object>)JSON.deserializeUntyped(metadataRes.getBody());
            downloadUrl = (String)dmap.get('url');

            if (String.isBlank(downloadUrl)) {
                result.error = 'Deliverable metadata did not include a download URL.';

                logEvent(
                    'Metadata missing download URL',
                    result.error,
                    'ERROR',
                    null,
                    operation,
                    envelopeId,
                    parentRecordId,
                    parentRecordId.getSObjectType().getDescribe().getName(),
                    metadataRes.getBody()
                );
                return result;
            }

            // -----------------------------------------------------------
            // 3) Download the file
            // -----------------------------------------------------------
            HttpRequest dlReq = new HttpRequest();
            dlReq.setEndpoint(downloadUrl);
            dlReq.setMethod('GET');

            HttpResponse dlRes = http.send(dlReq);
            status = dlRes.getStatusCode();

            if (status != 200) {
                result.error = 'File download failed: ' +
                               dlRes.getStatus() + ' ' + dlRes.getBody();

                logEvent(
                    'Downloading PDF from URL',
                    result.error,
                    'ERROR',
                    null,
                    operation,
                    envelopeId,
                    parentRecordId,
                    parentRecordId.getSObjectType().getDescribe().getName(),
                    JSON.serialize(new Map<String, Object>{
                        'downloadUrl'  => downloadUrl,
                        'statusCode'   => status,
                        'responseBody' => dlRes.getBody()
                    })
                );
                return result;
            }

            Blob pdfBlob = dlRes.getBodyAsBlob();

            // -----------------------------------------------------------
            // 4) Insert ContentVersion
            // -----------------------------------------------------------
            ContentVersion cv = new ContentVersion(
                Title = fileName,
                PathOnClient = fileName + '.pdf',
                VersionData = pdfBlob,
                FirstPublishLocationId = parentRecordId
            );
            insert cv;

            result.contentVersionId = cv.Id;
            return result;

        } catch (Exception ex) {
            result.error = ex.getMessage();

            logEvent(
                'Unhandled exception during download',
                result.error,
                'ERROR',
                ex,
                operation,
                envelopeId,
                parentRecordId,
                parentRecordId != null ?
                    parentRecordId.getSObjectType().getDescribe().getName() :
                    null,
                JSON.serialize(new Map<String, Object>{
                    'listEndpoint'     => listEndpoint,
                    'metadataEndpoint' => metadataEndpoint,
                    'downloadUrl'      => downloadUrl,
                    'envelopeId'       => envelopeId,
                    'parentRecordId'   => parentRecordId
                })
            );

            return result;
        }
    }

    // ================================================================
    // Convenience Overload
    // ================================================================
    public static DownloadResult downloadFinalDeliverableForEnvelopeRecord(
        Envelope__c env,
        String fileName
    ) {
        if (env == null) {
            DownloadResult res = new DownloadResult();
            res.error = 'Envelope record is null.';
            return res;
        }

        return downloadFinalDeliverable(
            env.Envelope_Id__c,
            env.Parent_Record_Id__c,
            String.isBlank(fileName) ? env.Name : fileName
        );
    }
}
