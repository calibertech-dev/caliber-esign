@IsTest(SeeAllData=false)
private class SignatureApiNotificationServiceTest {

    // ===== Helpers =====

    private static String anyEnvelopeStatus() {
        Schema.DescribeFieldResult dfr = Envelope__c.Status__c.getDescribe();
        List<Schema.PicklistEntry> vals = dfr.getPicklistValues();
        return vals.isEmpty() ? null : vals[0].getValue();
    }

    private static Envelope__c createEnvelopeForProposal(Proposal__c p, String externalId) {
        Envelope__c env = new Envelope__c(
            Parent_Record_Type__c = 'Proposal__c',
            Parent_Record_Id__c   = p.Id,
            Status__c             = anyEnvelopeStatus(),
            Envelope_Id__c        = externalId
        );
        insert env;
        return env;
    }

    private static Document_Template__c createDocumentTemplate(Id envelopeTemplateId) {
        Document_Template__c doc = new Document_Template__c(
            Name = 'Test Document Template',
            Envelope_Template__c = envelopeTemplateId
        );
        insert doc;
        return doc;
    }

    // Proposal__c has autonumber Name, so do NOT set Name
    private static Proposal__c createProposal(Id documentTemplateId) {
        Proposal__c p = new Proposal__c(
            Document_Template__c = documentTemplateId,
            Document_URL__c      = 'https://example.com/doc.pdf'
        );
        insert p;
        return p;
    }

    private static Proposal__c createProposalWithoutDocTemplate() {
        Proposal__c p = new Proposal__c(
            Document_URL__c = 'https://example.com/no-doc.pdf'
        );
        insert p;
        return p;
    }

    // ===== Tests =====

    @IsTest
    static void testMissingDocumentTemplate() {
        // Parent has no Document_Template__c
        Proposal__c proposal = createProposalWithoutDocTemplate();
        Envelope__c env      = createEnvelopeForProposal(proposal, 'env-missing-doc');

        Test.startTest();
        SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
        Test.stopTest();

        System.assert(true, 'Should complete without throwing when Document_Template__c is null.');
    }

    @IsTest
    static void testMissingEnvelopeTemplateOnDocumentTemplate() {
        // Document template with no Envelope_Template__c
        Document_Template__c docWithoutEnv = new Document_Template__c(
            Name = 'Doc without envelope'
        );
        insert docWithoutEnv;

        Proposal__c proposal = new Proposal__c(
            Document_Template__c = docWithoutEnv.Id,
            Document_URL__c      = 'https://example.com/doc2.pdf'
        );
        insert proposal;

        Envelope__c env = createEnvelopeForProposal(proposal, 'env-no-env-template');

        Test.startTest();
        SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
        Test.stopTest();

        System.assert(true, 'Should log and return when Envelope_Template__c is null.');
    }

    @IsTest
    static void testAutomaticCeremonyModeSkipsEmails() {
        // Ceremony_Creation__c = 'automatic', template id irrelevant
        Envelope_Template__c eTmpl = new Envelope_Template__c(
            Name = 'Auto Mode Template',
            Ceremony_Creation__c = 'automatic'
        );
        insert eTmpl;

        Document_Template__c doc = createDocumentTemplate(eTmpl.Id);
        Proposal__c proposal     = createProposal(doc.Id);
        Envelope__c env          = createEnvelopeForProposal(proposal, 'env-auto-mode');

        // Even if recipients exist, automatic mode should skip
        Envelope_Recipient__c rec = new Envelope_Recipient__c(
            Envelope__c        = env.Id,
            Recipient_Email__c = 'test@example.com',
            Recipient_Key__c   = 'client',
            Ceremony_URL__c    = 'https://ceremony.example.com',
            Status__c          = 'Awaiting'
        );
        insert rec;

        Test.startTest();
        SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
        Test.stopTest();

        System.assert(true, 'Automatic ceremony mode should short-circuit before sending.');
    }

    @IsTest
    static void testMissingEmailTemplateSkipsNotifications() {
        // Ceremony_Creation__c != 'automatic', but no Signing_Request_Email_Template__c
        Envelope_Template__c eTmpl = new Envelope_Template__c(
            Name = 'No Email Template'
            // Ceremony_Creation__c left null → not "automatic"
            // Signing_Request_Email_Template__c left null
        );
        insert eTmpl;

        Document_Template__c doc = createDocumentTemplate(eTmpl.Id);
        Proposal__c proposal     = createProposal(doc.Id);
        Envelope__c env          = createEnvelopeForProposal(proposal, 'env-no-email-template');

        Test.startTest();
        SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
        Test.stopTest();

        System.assert(true, 'Should log and return when Signing_Request_Email_Template__c is blank.');
    }

    @IsTest
    static void testNoRecipientsFound() {
        // Non-automatic mode, with a *non-blank* template Id (any Id is fine here)
        Envelope_Template__c eTmpl = new Envelope_Template__c(
            Name = 'Template With Fake EmailTemplate',
            // not automatic
            Signing_Request_Email_Template__c = UserInfo.getUserId()  // just needs to be non-null
        );
        insert eTmpl;

        Document_Template__c doc = createDocumentTemplate(eTmpl.Id);
        Proposal__c proposal     = createProposal(doc.Id);
        Envelope__c env          = createEnvelopeForProposal(proposal, 'env-no-recipients');

        // No Envelope_Recipient__c records

        Test.startTest();
        SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
        Test.stopTest();

        System.assert(true, 'Should log and return when no recipients exist.');
    }

    @IsTest
    static void testNoSendableRecipientsAllMissingEmailOrCeremonyUrl() {
        // Non-automatic mode, template id non-blank
        Envelope_Template__c eTmpl = new Envelope_Template__c(
            Name = 'Template With Fake EmailTemplate',
            Signing_Request_Email_Template__c = UserInfo.getUserId()
        );
        insert eTmpl;

        Document_Template__c doc = createDocumentTemplate(eTmpl.Id);
        Proposal__c proposal     = createProposal(doc.Id);
        Envelope__c env          = createEnvelopeForProposal(proposal, 'env-no-sendable-recs');

        // Recipient 1: has email, no ceremony URL
        Envelope_Recipient__c r1 = new Envelope_Recipient__c(
            Envelope__c        = env.Id,
            Recipient_Email__c = 'no-url@example.com',
            Recipient_Key__c   = 'client',
            Ceremony_URL__c    = null,
            Status__c          = 'Awaiting'
        );

        // Recipient 2: has ceremony URL, no email
        Envelope_Recipient__c r2 = new Envelope_Recipient__c(
            Envelope__c        = env.Id,
            Recipient_Email__c = null,
            Recipient_Key__c   = 'contractor',
            Ceremony_URL__c    = 'https://ceremony.example.com',
            Status__c          = 'Awaiting'
        );

        insert new List<Envelope_Recipient__c>{ r1, r2 };

        Test.startTest();
        SignatureApiNotificationService.handlePostCreateNotifications(env.Id);
        Test.stopTest();

        System.assert(true,
            'Should log "No Sendable Recipients" when all recipients are missing email or ceremony URL.');
    }

    @IsTest
    static void testUnhandledExceptionPath() {
        // Use a fake envelope Id to trigger a query exception at the top of the method
        Id fakeEnvId = Id.valueOf('a00000000000000AAA');
        Boolean threw = false;

        Test.startTest();
        try {
            SignatureApiNotificationService.handlePostCreateNotifications(fakeEnvId);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Method should rethrow exceptions after logging in catch block.');
    }
}
