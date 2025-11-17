@IsTest(SeeAllData=false)
private class SignatureApiEnvelopeOrchestrationTest {

    // Helper: create basic Envelope/Document templates
    private static Envelope_Template__c createEnvelopeTemplate() {
        Envelope_Template__c envTmpl = new Envelope_Template__c(
            Name = 'Test Envelope Template'
        );
        insert envTmpl;
        return envTmpl;
    }

    private static Document_Template__c createDocumentTemplate(Id envelopeTemplateId) {
        Document_Template__c docTmpl = new Document_Template__c(
            Name = 'Test Document Template',
            Envelope_Template__c = envelopeTemplateId
        );
        insert docTmpl;
        return docTmpl;
    }

    // Helper: create a Proposal__c as a valid parent with Document_Template__c
    // NOTE: Name is autonumber, so we do NOT set Name.
    private static Proposal__c createProposal(Id documentTemplateId) {
        Proposal__c proposal = new Proposal__c(
            Document_Template__c = documentTemplateId,
            Document_URL__c      = 'https://example.com/doc.pdf'
        );
        insert proposal;
        return proposal;
    }

    // Helper: create a Proposal__c without a Document_Template__c
    private static Proposal__c createProposalWithoutDocTemplate() {
        Proposal__c proposal = new Proposal__c(
            Document_URL__c = 'https://example.com/doc.pdf'
        );
        insert proposal;
        return proposal;
    }

    // Helper: create a Contact for signerRecordId linkage
    private static Contact createContact() {
        Contact c = new Contact(
            LastName = 'Signer',
            Email    = 'signer@example.com'
        );
        insert c;
        return c;
    }

    // Helper: create a dummy ContentVersion to use as document
    private static ContentVersion createContentVersion() {
        ContentVersion cv = new ContentVersion(
            Title        = 'Test File',
            PathOnClient = 'test.pdf',
            VersionData  = Blob.valueOf('test file')
        );
        insert cv;
        return cv;
    }

    @IsTest
    static void testCreateAndSendEnvelope_HappyPath_ExplicitParentType() {
        // Setup: template chain + parent
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);
        Proposal__c proposal         = createProposal(docTmpl.Id);

        Contact signer    = createContact();
        ContentVersion cv = createContentVersion();

        // Build request with explicit parentSObjectType
        SignatureApiEnvelopeOrchestrationService.SendRequest req =
            new SignatureApiEnvelopeOrchestrationService.SendRequest();
        req.parentRecordId    = proposal.Id;
        req.parentSObjectType = 'Proposal__c';
        req.sendImmediately   = true;

        // Recipients: one without signer, one with signer
        SignatureApiEnvelopeOrchestrationService.RecipientInput r1 =
            new SignatureApiEnvelopeOrchestrationService.RecipientInput();
        r1.recipientKey = 'client';
        r1.name         = 'Client Name';
        r1.email        = 'client@example.com';

        SignatureApiEnvelopeOrchestrationService.RecipientInput r2 =
            new SignatureApiEnvelopeOrchestrationService.RecipientInput();
        r2.recipientKey   = 'contractor';
        r2.name           = 'Contractor Name';
        r2.email          = 'contractor@example.com';
        r2.signerRecordId = signer.Id;

        req.recipients = new List<SignatureApiEnvelopeOrchestrationService.RecipientInput>{ r1, r2 };

        // Documents: one with ContentVersion Id
        SignatureApiEnvelopeOrchestrationService.DocumentInput d1 =
            new SignatureApiEnvelopeOrchestrationService.DocumentInput();
        d1.contentVersionId = cv.Id;
        req.documents = new List<SignatureApiEnvelopeOrchestrationService.DocumentInput>{ d1 };

        Test.startTest();
        SignatureApiEnvelopeOrchestrationService.SendResult res =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(req);
        Test.stopTest();

        System.assertNotEquals(null, res, 'Result should not be null');
        System.assertNotEquals(null, res.envelopeId, 'Envelope Id should be populated');

        // Envelope exists
        Envelope__c env = [
            SELECT Id, Parent_Record_Id__c, Parent_Record_Type__c, Status__c
            FROM Envelope__c
            WHERE Id = :res.envelopeId
        ];
        System.assertEquals(proposal.Id, env.Parent_Record_Id__c, 'Parent should be the Proposal');
        System.assertEquals('Proposal__c', env.Parent_Record_Type__c, 'Parent type should be Proposal__c');
        System.assertNotEquals(null, env.Status__c, 'Status__c should be initialized by getInitialEnvelopeStatus');

        // Recipients created and linked correctly
        List<Envelope_Recipient__c> recs = [
            SELECT Id, Envelope__c, Recipient_Email__c, Recipient_Key__c,
                   Parent_Record_Id__c, Parent_Record_Type__c, Status__c
            FROM Envelope_Recipient__c
            WHERE Envelope__c = :env.Id
            ORDER BY Recipient_Key__c
        ];
        System.assertEquals(2, recs.size(), 'Two recipients should have been created');

        Envelope_Recipient__c first  = recs[0];
        Envelope_Recipient__c second = recs[1];

        // First recipient: no signer linkage
        System.assertEquals('client@example.com', first.Recipient_Email__c);
        System.assertEquals('client', first.Recipient_Key__c);
        System.assertEquals('Awaiting', first.Status__c);

        // Second recipient: has signer linkage to Contact
        System.assertEquals('contractor', second.Recipient_Key__c);
        System.assertEquals(signer.Id, second.Parent_Record_Id__c);
        System.assertEquals('Contact', second.Parent_Record_Type__c);
    }

    @IsTest
    static void testCreateAndSendEnvelope_HappyPath_InferParentType_SendImmediatelyNull() {
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);
        Proposal__c proposal         = createProposal(docTmpl.Id);

        SignatureApiEnvelopeOrchestrationService.SendRequest req =
            new SignatureApiEnvelopeOrchestrationService.SendRequest();
        req.parentRecordId    = proposal.Id;
        req.parentSObjectType = null; // should be inferred from Id.getSObjectType()
        req.recipients        = null; // exercise the null branch (no recipients)
        req.documents         = new List<SignatureApiEnvelopeOrchestrationService.DocumentInput>(); // empty
        req.sendImmediately   = null; // should default to true

        Test.startTest();
        SignatureApiEnvelopeOrchestrationService.SendResult res =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(req);
        Test.stopTest();

        System.assertNotEquals(null, res.envelopeId, 'Envelope should still be created');

        // No recipients created
        Integer recCount = [
            SELECT COUNT()
            FROM Envelope_Recipient__c
            WHERE Envelope__c = :res.envelopeId
        ];
        System.assertEquals(0, recCount, 'No recipients expected for null list');
    }

    @IsTest
    static void testCreateAndSendEnvelope_UnsupportedParentType() {
        // Use a standard object here: parent type will be "Account"
        Account acc = new Account(Name = 'Unsupported Parent');
        insert acc;

        SignatureApiEnvelopeOrchestrationService.SendRequest req =
            new SignatureApiEnvelopeOrchestrationService.SendRequest();
        req.parentRecordId    = acc.Id;
        req.parentSObjectType = 'Account';  // explicitly unsupported

        Test.startTest();
        SignatureApiEnvelopeOrchestrationService.SendResult res =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(req);
        Test.stopTest();

        System.assertNotEquals(null, res, 'Result should not be null');
        System.assertNotEquals(null, res.errorMessage, 'Error message should be populated');
        System.assertEquals(null, res.envelopeId, 'Envelope should not be created for unsupported parent type');
    }

    @IsTest
    static void testCreateAndSendEnvelope_NullRequestAndMissingParentId() {
        SignatureApiEnvelopeOrchestrationService.SendResult resNull;
        SignatureApiEnvelopeOrchestrationService.SendResult resNoParent;

        Test.startTest();
        // Case 1: null request
        resNull =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(null);

        // Case 2: request with null parentRecordId
        SignatureApiEnvelopeOrchestrationService.SendRequest req =
            new SignatureApiEnvelopeOrchestrationService.SendRequest();
        req.parentRecordId    = null;
        req.parentSObjectType = 'Proposal__c';

        resNoParent =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(req);
        Test.stopTest();

        System.assertNotEquals(null, resNull, 'Result should not be null for null request');
        System.assertNotEquals(null, resNull.errorMessage, 'Error message should be set for null request');

        System.assertNotEquals(null, resNoParent);
        System.assertNotEquals(null, resNoParent.errorMessage,
            'Missing parentRecordId should produce a validation error');
        System.assertEquals(null, resNoParent.envelopeId,
            'Envelope should not be created when parentRecordId is missing');
    }

    @IsTest
    static void testCreateAndSendEnvelope_NoDocumentTemplateOrEnvelopeTemplate() {
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);

        // 1) Parent has no Document_Template__c
        Proposal__c proposalNoDoc = createProposalWithoutDocTemplate();

        SignatureApiEnvelopeOrchestrationService.SendRequest req1 =
            new SignatureApiEnvelopeOrchestrationService.SendRequest();
        req1.parentRecordId    = proposalNoDoc.Id;
        req1.parentSObjectType = 'Proposal__c';

        // 2) Parent has Document_Template__c whose Envelope_Template__c is null
        Document_Template__c docWithoutEnv = new Document_Template__c(
            Name = 'Doc without envelope'
            // Envelope_Template__c left null intentionally
        );
        insert docWithoutEnv;

        Proposal__c proposalBadEnv = new Proposal__c(
            Document_Template__c = docWithoutEnv.Id,
            Document_URL__c      = 'https://example.com/doc2.pdf'
        );
        insert proposalBadEnv;

        SignatureApiEnvelopeOrchestrationService.SendRequest req2 =
            new SignatureApiEnvelopeOrchestrationService.SendRequest();
        req2.parentRecordId    = proposalBadEnv.Id;
        req2.parentSObjectType = 'Proposal__c';

        SignatureApiEnvelopeOrchestrationService.SendResult res1;
        SignatureApiEnvelopeOrchestrationService.SendResult res2;

        Test.startTest();
        res1 =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(req1);
        res2 =
            SignatureApiEnvelopeOrchestrationService.createAndSendEnvelope(req2);
        Test.stopTest();

        System.assertNotEquals(null, res1.errorMessage,
            'Should fail when Document_Template__c is null');
        System.assertEquals(null, res1.envelopeId,
            'Envelope should not be created when document template missing');

        System.assertNotEquals(null, res2.errorMessage,
            'Should fail when Envelope_Template__c is null on Document_Template__c');
        System.assertEquals(null, res2.envelopeId,
            'Envelope should not be created when envelope template missing');
    }

    @IsTest
    static void testLoadParent_SuccessAndErrors() {
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);
        Proposal__c proposal         = createProposal(docTmpl.Id);

        // Happy path: correct type and Id
        SObject parent = SignatureApiEnvelopeOrchestrationService.loadParent(
            proposal.Id,
            'Proposal__c'
        );
        System.assertNotEquals(null, parent, 'Parent should be loaded');
        System.assertEquals(proposal.Id, parent.get('Id'));

        // Error: missing type
        Boolean missingTypeThrown = false;
        try {
            SignatureApiEnvelopeOrchestrationService.loadParent(
                proposal.Id,
                null
            );
        } catch (AuraHandledException e) {
            missingTypeThrown = true;
        }
        System.assert(missingTypeThrown, 'Missing type should throw AuraHandledException');

        // Error: missing Id
        Boolean missingIdThrown = false;
        try {
            SignatureApiEnvelopeOrchestrationService.loadParent(
                null,
                'Proposal__c'
            );
        } catch (AuraHandledException e) {
            missingIdThrown = true;
        }
        System.assert(missingIdThrown, 'Missing Id should throw AuraHandledException');

        // Error: parent not found
        Boolean notFoundThrown = false;
        try {
            SignatureApiEnvelopeOrchestrationService.loadParent(
                Id.valueOf('a00000000000000AAA'),
                'Proposal__c'
            );
        } catch (AuraHandledException e) {
            notFoundThrown = true;
        }
        System.assert(notFoundThrown, 'Non-existent parent should throw AuraHandledException');
    }
}
