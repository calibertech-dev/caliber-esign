public with sharing class SignatureApiEnvelopeOrchestrationService {

    public class RecipientInput {
        @AuraEnabled public String recipientKey;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public Id signerRecordId;      // Contact/User
    }

    public class DocumentInput {
        @AuraEnabled public Id contentVersionId; // optional
    }

    public class SendRequest {
        @AuraEnabled public Id parentRecordId;
        @AuraEnabled public String parentSObjectType; // optional hint
        @AuraEnabled public List<RecipientInput> recipients;
        @AuraEnabled public List<DocumentInput> documents;
        @AuraEnabled public Boolean sendImmediately;
    }

    public class SendResult {
        @AuraEnabled public Id envelopeId;
        @AuraEnabled public String signatureApiEnvelopeId;
        @AuraEnabled public String status;
        @AuraEnabled public String errorMessage;
    }

    // ------------------------------------------------------------------
    // Logging: [Caliber eSign] / APEX / this class
    // ------------------------------------------------------------------
    private static final String LOG_CONTEXT_PREFIX = '[Caliber eSign] Envelope Orchestration';
    private static final String LOG_SOURCE         = 'APEX';
    private static final String LOG_COMPONENT      = 'SignatureApiEnvelopeOrchestrationService';

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
                LOG_SOURCE,       // Source__c (APEX)
                LOG_COMPONENT,    // Component__c
                operation,        // Operation__c
                parentRecordId,
                parentRecordType
            );
        } catch (Exception ignore) {
            // Never let logging break the main path
        }
    }

    @AuraEnabled
    public static SendResult createAndSendEnvelope(SendRequest req) {
        SendResult result = new SendResult();

        // Correlation + parent context we’ll fill as we go
        Id envelopeId;
        Id parentRecordId   = req != null ? req.parentRecordId : null;
        String parentTypeName;
        String correlationId;

        try {
            if (req == null) {
                throw new AuraHandledException('Request payload is required.');
            }

            if (req.parentRecordId == null) {
                throw new AuraHandledException('Parent record Id is required.');
            }

            // ==== 1) Resolve parent type safely ====
            if (!String.isBlank(req.parentSObjectType)) {
                parentTypeName = req.parentSObjectType;
            } else {
                parentTypeName = req.parentRecordId.getSObjectType().getDescribe().getName();
            }

            // Only support the Envelope parent types you actually allow in the picklist
            Set<String> allowedParentTypes = new Set<String>{
                'Contract__c',
                'Contract_Amendment__c',
                'Proposal__c'
            };
            if (!allowedParentTypes.contains(parentTypeName)) {
                throw new AuraHandledException(
                    'Unsupported parent type for SignatureApi envelopes: ' + parentTypeName
                );
            }

            correlationId = String.valueOf(req.parentRecordId);

            // ==== 2) Load parent & document template ====
            SObject parent = loadParent(req.parentRecordId, parentTypeName);

            Id documentTemplateId = (Id)parent.get('Document_Template__c');
            if (documentTemplateId == null) {
                throw new AuraHandledException('No Document Template found on parent record.');
            }

            Document_Template__c docTmpl = [
                SELECT Id, Name, Envelope_Template__c
                FROM Document_Template__c
                WHERE Id = :documentTemplateId
            ];

            if (docTmpl.Envelope_Template__c == null) {
                throw new AuraHandledException('No Envelope Template linked to this Document Template.');
            }

            Envelope_Template__c envTmpl = [
                SELECT Id, Name
                FROM Envelope_Template__c
                WHERE Id = :docTmpl.Envelope_Template__c
            ];

            // ==== 3) Create Envelope__c (user-facing record) ====
            Envelope__c env = new Envelope__c();
            // Name is Auto Number
            env.Parent_Record_Type__c = parentTypeName;
            env.Parent_Record_Id__c   = req.parentRecordId;
            env.Status__c             = getInitialEnvelopeStatus();
            insert env;

            envelopeId   = env.Id;
            correlationId = String.valueOf(envelopeId); // Prefer the envelope as correlation
            result.envelopeId = envelopeId;

            // Populate Parent_Record_Name__c so your formula link works
            List<SObject> envWrapper = new List<SObject>();
            envWrapper.add(env);
            PolymorphicRecordNameUtil.updateRecordNames(envWrapper);
            update env;

            // ==== 4) Create Envelope_Recipient__c records ====
            if (req.recipients != null) {
                List<Envelope_Recipient__c> toInsert = new List<Envelope_Recipient__c>();
                for (RecipientInput inRec : req.recipients) {
                    if (inRec == null) continue;

                    Envelope_Recipient__c r = new Envelope_Recipient__c();
                    r.Envelope__c        = env.Id;
                    r.Recipient_Email__c = inRec.email;
                    r.Recipient_Key__c   = inRec.recipientKey;
                    r.Status__c          = 'Awaiting';

                    // Optional signer linking (Contact/User)
                    if (inRec.signerRecordId != null) {
                        Id signerId     = inRec.signerRecordId;
                        String typeName = signerId.getSObjectType().getDescribe().getName(); // 'Contact' or 'User'
                        r.Parent_Record_Id__c   = signerId;
                        r.Parent_Record_Type__c = typeName;
                    }

                    toInsert.add(r);
                }
                if (!toInsert.isEmpty()) {
                    insert toInsert;

                    // Populate Parent_Record_Name__c for each recipient
                    List<SObject> recWrapper = new List<SObject>();
                    recWrapper.addAll(toInsert);
                    PolymorphicRecordNameUtil.updateRecordNames(recWrapper);
                    update toInsert;
                }
            }

            // ==== 5) Determine ContentVersion Id (if any) ====
            Id contentVersionId;
            if (req.documents != null && !req.documents.isEmpty()) {
                DocumentInput firstDoc = req.documents[0];
                if (firstDoc != null) {
                    contentVersionId = firstDoc.contentVersionId;
                }
            }

            // ==== 6) Delegate to builder service ====
            Boolean sendNow = (req.sendImmediately == null) ? true : req.sendImmediately;

            SignatureApiEnvelopeBuilderService.BuildContext ctx =
                new SignatureApiEnvelopeBuilderService.BuildContext(
                    env.Id,
                    sendNow,
                    contentVersionId
                );

            SignatureApiEnvelopeBuilderService.BuildResult buildRes =
                SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);

            result.signatureApiEnvelopeId = buildRes.signatureApiEnvelopeId;
            result.status                 = buildRes.status;
            result.errorMessage           = buildRes.errorMessage;

            // Log if builder reported an error even though we didn’t throw
            if (!String.isBlank(buildRes.errorMessage)) {
                logEvent(
                    'createAndSendEnvelope for parent ' + String.valueOf(req.parentRecordId),
                    'Envelope builder reported error: ' + buildRes.errorMessage,
                    'ERROR',
                    null,
                    'createAndSendEnvelope',
                    correlationId,
                    req.parentRecordId,
                    parentTypeName,
                    JSON.serialize(new Map<String, Object>{
                        'envelopeId'              => envelopeId,
                        'parentRecordId'          => req.parentRecordId,
                        'parentSObjectType'       => parentTypeName,
                        'sendImmediately'         => sendNow,
                        'contentVersionId'        => contentVersionId,
                        'builderStatus'           => buildRes.status,
                        'builderEnvelopeId'       => buildRes.signatureApiEnvelopeId,
                        'builderErrorMessage'     => buildRes.errorMessage
                    })
                );
            }

            // ==== 7) Post-create notifications ====
            if (String.isBlank(buildRes.errorMessage)) {
                SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
            }

            return result;

        } catch (Exception ex) {
            result.errorMessage = ex.getMessage();

            // AuraHandledException => WARN (expected/user-visible validation),
            // everything else => ERROR
            String severity = (ex instanceof AuraHandledException) ? 'WARN' : 'ERROR';

            logEvent(
                'createAndSendEnvelope for parent ' + String.valueOf(parentRecordId),
                ex.getMessage(),
                severity,
                ex,
                'createAndSendEnvelope',
                correlationId,
                parentRecordId,
                parentTypeName,
                JSON.serialize(new Map<String, Object>{
                    'parentRecordId'    => parentRecordId,
                    'parentSObjectType' => parentTypeName,
                    'envelopeId'        => envelopeId,
                    'request'           => req
                })
            );

            return result;
        }
    }

    private static String getInitialEnvelopeStatus() {
        Schema.DescribeFieldResult dfr = Envelope__c.Status__c.getDescribe();
        List<Schema.PicklistEntry> vals = dfr.getPicklistValues();
        if (vals.isEmpty()) {
            return null;
        }
        return vals[0].getValue(); // e.g. Processing / In Progress
    }

    public static SObject loadParent(Id parentId, String sobjectType) {
        if (String.isBlank(sobjectType) || parentId == null) {
            throw new AuraHandledException('Parent record type or Id missing.');
        }

        String soql;

        if (sobjectType == 'Contract__c' ||
            sobjectType == 'Contract_Amendment__c' ||
            sobjectType == 'Proposal__c') {

            soql =
                'SELECT Id, Name, Document_Template__c, Document_URL__c ' +
                'FROM ' + sobjectType + ' ' +
                'WHERE Id = :parentId';
        } else {
            soql =
                'SELECT Id, Name, Document_Template__c ' +
                'FROM ' + sobjectType + ' ' +
                'WHERE Id = :parentId';
        }

        List<SObject> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new AuraHandledException('Parent record not found.');
        }
        return rows[0];
    }
}
