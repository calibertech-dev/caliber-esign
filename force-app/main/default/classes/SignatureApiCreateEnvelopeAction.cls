public with sharing class SignatureApiCreateEnvelopeAction {

    // ====== Flow input types ======
    public class RecipientInput {
        @InvocableVariable(
            label='Recipient Key' required=true
            description='Key used to map this recipient to SignatureApi and Place Templates (e.g. client, contractor).'
        )
        public String recipientKey;

        @InvocableVariable(
            label='Recipient Name' required=true
            description='Display name of the signer.'
        )
        public String name;

        @InvocableVariable(
            label='Recipient Email' required=true
            description='Email address of the signer.'
        )
        public String email;

        // NEW: signer record (Contact or User) – optional
        @InvocableVariable(
            label='Signer Record Id (Contact/User)'
            description='Optional: Salesforce Id of the signer Contact or User record, if available.'
        )
        public Id signerRecordId;
    }

    public class DocumentInput {
        @InvocableVariable(
            label='Content Version Id'
            description='ContentVersion Id of the document to send as part of the envelope.'
        )
        public Id contentVersionId;
    }

    public class Request {
        @InvocableVariable(
            label='Parent Record Id' required=true
            description='Id of the Contract, Contract Amendment, Proposal, or other parent record.'
        )
        public Id parentRecordId;

        @InvocableVariable(
            label='Parent SObject Type'
            description='API name of the parent record SObject type (e.g. Contract__c, Contract_Amendment__c, Proposal__c).'
        )
        public String parentRecordType;

        @InvocableVariable(
            label='Recipients' required=true
            description='List of envelope recipients (client, contractor, etc.).'
        )
        public List<RecipientInput> recipients;

        @InvocableVariable(
            label='Documents'
            description='List of documents (by ContentVersionId) to include in the envelope. If not provided, the ContentVersion Id field or parent Document_URL__c may be used.'
        )
        public List<DocumentInput> documents;

        @InvocableVariable(
            label='Content Version Id'
            description='Optional ContentVersion Id of the document to send. Used for backward compatibility if Documents are not specified.'
        )
        public Id contentVersionId;

        @InvocableVariable(
            label='Send Immediately?'
            description='If true, the envelope is sent immediately. Reserved for future behavior; currently informational.'
        )
        public Boolean sendImmediately;
    }

    // ====== Flow output type ======
    public class Response {
        @InvocableVariable(
            label='Envelope Id'
            description='Salesforce Id of the created Envelope__c record.'
        )
        public Id envelopeId;

        @InvocableVariable(
            label='SignatureApi Envelope Id'
            description='External SignatureApi envelope id.'
        )
        public String signatureApiEnvelopeId;

        @InvocableVariable(
            label='Status'
            description='Status returned by SignatureApi for the envelope.'
        )
        public String status;

        @InvocableVariable(
            label='Error Message'
            description='Any error encountered while creating or sending the envelope.'
        )
        public String errorMessage;
    }

    // ====== Logging config & helper ======

    // Context is a Long Text Area; we encode package + subsystem here.
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] SignatureAPI Envelope';
    // This is an Invocable used from Flow.
    private static final String LOG_SOURCE_FLOW    = 'FLOW';
    // Component is the technical unit: this class.
    private static final String LOG_COMPONENT      = 'SignatureApiCreateEnvelopeAction';

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
                fullContext,       // Context__c
                message,           // Message__c
                severity,          // Severity__c
                correlationId,     // Correlation_Id__c
                ex,
                payloadJson,       // Payload__c
                LOG_SOURCE_FLOW,   // Source__c (FLOW)
                LOG_COMPONENT,     // Component__c
                operation,         // Operation__c
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignore) {
            // Logging must never break Flow execution
        }
    }

    // ====== Invocable entry point for Flow ======
    @InvocableMethod(
        label='SignatureApi - Create Envelope'
        description='Creates Envelope__c and Envelope_Recipient__c records, sends the envelope to SignatureApi using templates, and returns ids and status.'
    )
    public static List<Response> createEnvelopes(List<Request> requests) {
        List<Response> out = new List<Response>();

        for (Request req : requests) {
            Response r = new Response();

            // Per-request context for logging
            Id parentRecordId        = req.parentRecordId;
            String parentRecordType  = req.parentRecordType;
            String correlationId     = parentRecordId != null ? String.valueOf(parentRecordId) : null;
            String contextDetail     = 'Create envelope for parent ' + String.valueOf(parentRecordId);

            SignatureApiEnvelopeOrchestrationService.SendRequest sReq =
                new SignatureApiEnvelopeOrchestrationService.SendRequest();
            SignatureApiEnvelopeOrchestrationService.SendResult sRes;

            try {
                sReq.parentRecordId    = req.parentRecordId;
                sReq.parentSObjectType = req.parentRecordType;
                sReq.sendImmediately   = req.sendImmediately;

                // Map recipients to orchestration DTO
                if (req.recipients != null) {
                    sReq.recipients = new List<SignatureApiEnvelopeOrchestrationService.RecipientInput>();
                    for (RecipientInput inRec : req.recipients) {
                        if (inRec == null) continue;

                        SignatureApiEnvelopeOrchestrationService.RecipientInput outRec =
                            new SignatureApiEnvelopeOrchestrationService.RecipientInput();
                        outRec.recipientKey   = inRec.recipientKey;
                        outRec.name           = inRec.name;
                        outRec.email          = inRec.email;
                        outRec.signerRecordId = inRec.signerRecordId; // optional
                        sReq.recipients.add(outRec);
                    }
                }

                // Map documents to orchestration DTO
                if (req.documents != null) {
                    sReq.documents = new List<SignatureApiEnvelopeOrchestrationService.DocumentInput>();
                    for (DocumentInput inDoc : req.documents) {
                        if (inDoc == null) continue;

                        SignatureApiEnvelopeOrchestrationService.DocumentInput outDoc =
                            new SignatureApiEnvelopeOrchestrationService.DocumentInput();
                        outDoc.contentVersionId = inDoc.contentVersionId;
                        sReq.documents.add(outDoc);
                    }
                } else if (req.contentVersionId != null) {
                    // Backwards-compat: single contentVersionId
                    sReq.documents = new List<SignatureApiEnvelopeOrchestrationService.DocumentInput>();
                    SignatureApiEnvelopeOrchestrationService.DocumentInput outDoc =
                        new SignatureApiEnvelopeOrchestrationService.DocumentInput();
                    outDoc.contentVersionId = req.contentVersionId;
                    sReq.documents.add(outDoc);
                }

                // Core orchestration call
                sRes = SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(sReq);

                // Update correlationId once we know the SignatureApi envelope id
                if (!String.isBlank(sRes.signatureApiEnvelopeId)) {
                    correlationId = sRes.signatureApiEnvelopeId;
                }

                // Map result to Flow response
                r.envelopeId             = sRes.envelopeId;
                r.signatureApiEnvelopeId = sRes.signatureApiEnvelopeId;
                r.status                 = sRes.status;
                r.errorMessage           = sRes.errorMessage;

                // If the orchestration reported an error, log it (even though we didn't throw)
                if (!String.isBlank(sRes.errorMessage)) {
                    String payloadJson = JSON.serialize(new Map<String, Object>{
                        'sendRequest'  => sReq,
                        'sendResult'   => new Map<String, Object>{
                            'envelopeId'             => sRes.envelopeId,
                            'signatureApiEnvelopeId' => sRes.signatureApiEnvelopeId,
                            'status'                 => sRes.status,
                            'errorMessage'           => sRes.errorMessage
                        }
                    });

                    logEvent(
                        contextDetail,
                        sRes.errorMessage,
                        'ERROR', // this is an actual failure path
                        null,
                        'createEnvelopes',
                        correlationId,
                        parentRecordId,
                        parentRecordType,
                        payloadJson
                    );
                }

            } catch (Exception ex) {
                // Populate Flow response with the exception message
                r.errorMessage = ex.getMessage();

                String payloadJson = JSON.serialize(new Map<String, Object>{
                    'sendRequest'   => sReq,
                    'parentRecordId'=> parentRecordId,
                    'parentRecordType' => parentRecordType
                });

                logEvent(
                    contextDetail,
                    'Unhandled exception during envelope creation: ' + ex.getMessage(),
                    'ERROR',
                    ex,
                    'createEnvelopes',
                    correlationId,
                    parentRecordId,
                    parentRecordType,
                    payloadJson
                );
            }

            out.add(r);
        }

        return out;
    }
}
