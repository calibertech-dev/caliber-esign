@IsTest
private class SignatureApiEnvelopeBuilderServiceTest {

    // --------------------------------------------------------
    // Test data helpers
    // --------------------------------------------------------

    private static Envelope_Template__c createEnvelopeTemplate() {
        Envelope_Template__c t = new Envelope_Template__c(
            Name                 = 'Test Env Template',
            // Branding__c is a lookup in your org – do NOT set it to 'Default'
            Default_Topics__c    = 'Hello from Caliber',
            Routing_Mode__c      = 'Parallel',   // exercise routing == 'parallel'
            Ceremony_Creation__c = 'Automatic'   // ceremonyMode == 'automatic'
        );
        insert t;
        return t;
    }

    private static Document_Template__c createDocumentTemplate(Id envTemplateId) {
        Document_Template__c d = new Document_Template__c(
            Name                 = 'Test Doc Template',
            Envelope_Template__c = envTemplateId
        );
        insert d;
        return d;
    }

    private static Proposal__c createProposal(Boolean withDocTemplate, Id docTemplateId) {
        // Name is an autonumber – do not set it
        Proposal__c p = new Proposal__c();
        if (withDocTemplate && docTemplateId != null) {
            p.Document_Template__c = docTemplateId;
        }
        insert p;
        return p;
    }

    private static Envelope__c createEnvelopeWithParent(Proposal__c parent) {
        Envelope__c env = new Envelope__c(
            // Name is autonumber – do not set
            Parent_Record_Id__c   = parent.Id,
            Parent_Record_Type__c = 'Proposal__c'
            // Envelope_Id__c left null to test correlation fallback
        );
        insert env;
        return env;
    }

    private static void createRecipientsForEnvelope(Envelope__c env) {
        // Name is autonumber; only set fields the builder uses
        Envelope_Recipient__c r1 = new Envelope_Recipient__c(
            Envelope__c        = env.Id,
            Recipient_Key__c   = 'client',
            Recipient_Email__c = 'client@example.com'
        );
        Envelope_Recipient__c r2 = new Envelope_Recipient__c(
            Envelope__c        = env.Id,
            Recipient_Key__c   = 'contractor',
            Recipient_Email__c = 'contractor@example.com'
        );
        insert new List<Envelope_Recipient__c>{ r1, r2 };
    }

    private static ContentVersion createContentVersion() {
        ContentVersion cv = new ContentVersion(
            Title        = 'TestDoc',
            PathOnClient = 'TestDoc.pdf',
            VersionData  = Blob.valueOf('PDF_BYTES')
        );
        insert cv;
        return cv;
    }

    // --------------------------------------------------------
    // HTTP mocks
    // --------------------------------------------------------

    // Full-flow mock: file create, file upload, envelope create with recipients
    private class FullFlowMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();

            if (endpoint.contains('/v1/files')) {
                // Step 1: create file shell
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"id":"file-123","put_url":"callout:SignatureApi/put/file-123"}');
                return res;

            } else if (endpoint.contains('/put/file-123')) {
                // Step 2: upload blob
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{}');
                return res;

            } else if (endpoint.contains('/v1/envelopes')) {
                // Step 3: create envelope – deliberately omit "status"
                String body =
                    '{' +
                        '"id":"env-ext-456",' +
                        '"recipients":[' +
                            '{' +
                                '"id":"rec-ext-1",' +
                                '"key":"client",' +
                                '"status":"pending",' +
                                '"url":"https://ceremony.example.com/c1",' +
                                '"email":"client@example.com",' +
                                '"name":"Client One"' +
                            '},' +
                            '{' +
                                '"id":"rec-ext-2",' +
                                '"key":"contractor",' +
                                '"status":"pending",' +
                                '"url":"https://ceremony.example.com/c2",' +
                                '"email":"contractor@example.com",' +
                                '"name":"Contractor One"' +
                            '}' +
                        ']' +
                    '}';
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody(body);
                return res;

            } else {
                // Safety fallback
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setBody('{}');
                return res;
            }
        }
    }

    // Mock only for /v1/envelopes, no recipients (exercise early-return in applyCeremonyUrls)
    private class EnvelopeOnlyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/v1/envelopes')) {
                // Only id, no status → avoids restricted picklist issues
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"id":"env-ext-empty"}');
                return res;
            }
            res.setStatusCode(200);
            res.setStatus('200 OK');
            res.setBody('{}');
            return res;
        }
    }

    // --------------------------------------------------------
    // Tests
    // --------------------------------------------------------

    @IsTest
    static void testBuildAndSendEnvelope_ContentVersion_Success() {
        // Arrange
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);
        Proposal__c parent = createProposal(true, docTmpl.Id);
        Envelope__c env = createEnvelopeWithParent(parent);
        createRecipientsForEnvelope(env);
        ContentVersion cv = createContentVersion();

        SignatureApiEnvelopeBuilderService.BuildContext ctx =
            new SignatureApiEnvelopeBuilderService.BuildContext(
                env.Id,
                true,
                cv.Id
            );

        Test.setMock(HttpCalloutMock.class, new FullFlowMock());

        // Act
        SignatureApiEnvelopeBuilderService.BuildResult result;
        Test.startTest();
        result = SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);
        Test.stopTest();

        // Assert
        System.assertEquals(env.Id, result.envelopeId);
        System.assertEquals(null, result.errorMessage, 'No error expected on success');
        System.assertEquals('env-ext-456', result.signatureApiEnvelopeId);
        System.assertEquals(null, result.status, 'Status should be null because mock omitted it');

        // Envelope should be updated with external id; status remains null
        env = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('env-ext-456', env.Envelope_Id__c);
        System.assertEquals(null, env.Status__c);

        // Recipients should have recipient id + ceremony URL mapped
        List<Envelope_Recipient__c> recs = [
            SELECT Recipient_Key__c, Recipient_Id__c, Ceremony_URL__c
            FROM Envelope_Recipient__c
            WHERE Envelope__c = :env.Id
            ORDER BY Recipient_Key__c
        ];
        System.assertEquals(2, recs.size());
        System.assertEquals('client', recs[0].Recipient_Key__c);
        System.assertEquals('rec-ext-1', recs[0].Recipient_Id__c);
        System.assertEquals('https://ceremony.example.com/c1', recs[0].Ceremony_URL__c);
        System.assertEquals('contractor', recs[1].Recipient_Key__c);
        System.assertEquals('rec-ext-2', recs[1].Recipient_Id__c);
        System.assertEquals('https://ceremony.example.com/c2', recs[1].Ceremony_URL__c);
    }

    @IsTest
    static void testBuildAndSendEnvelope_DocumentUrl_Success_RecipientsUntouched() {
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);

        // Parent with Document_URL__c set and doc template
        Proposal__c parent = new Proposal__c(
            Document_Template__c = docTmpl.Id,
            Document_URL__c      = 'https://files.example.com/doc.pdf'
        );
        insert parent;

        Envelope__c env = createEnvelopeWithParent(parent);
        createRecipientsForEnvelope(env);

        SignatureApiEnvelopeBuilderService.BuildContext ctx =
            new SignatureApiEnvelopeBuilderService.BuildContext(
                env.Id,
                false
            );

        Test.setMock(HttpCalloutMock.class, new EnvelopeOnlyMock());

        Test.startTest();
        SignatureApiEnvelopeBuilderService.BuildResult result =
            SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);
        Test.stopTest();

        System.assertEquals(null, result.errorMessage, 'Should still be treated as success');
        System.assertEquals('env-ext-empty', result.signatureApiEnvelopeId);
        System.assertEquals(null, result.status);

        // Envelope updated with id, status remains null
        env = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Id = :env.Id
        ];
        System.assertEquals('env-ext-empty', env.Envelope_Id__c);
        System.assertEquals(null, env.Status__c);

        // applyCeremonyUrls should have early-returned (no recipients in response),
        // so Recipient_Id__c and Ceremony_URL__c remain null.
        List<Envelope_Recipient__c> recs = [
            SELECT Recipient_Key__c, Recipient_Id__c, Ceremony_URL__c
            FROM Envelope_Recipient__c
            WHERE Envelope__c = :env.Id
        ];
        for (Envelope_Recipient__c r : recs) {
            System.assertEquals(null, r.Recipient_Id__c);
            System.assertEquals(null, r.Ceremony_URL__c);
        }
    }

    @IsTest
    static void testBuildAndSendEnvelope_NoDocumentTemplateOnParent() {
        // Parent without Document_Template__c
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);
        // Parent WITHOUT wiring Document_Template__c
        Proposal__c parent = createProposal(false, null);

        Envelope__c env = createEnvelopeWithParent(parent);

        SignatureApiEnvelopeBuilderService.BuildContext ctx =
            new SignatureApiEnvelopeBuilderService.BuildContext(env.Id, true);

        Test.startTest();
        SignatureApiEnvelopeBuilderService.BuildResult result =
            SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);
        Test.stopTest();

        System.assertNotEquals(null, result.errorMessage);
        System.assert(
            result.errorMessage.contains('No Document Template found on parent record.'),
            'Should report missing document template'
        );
    }

    @IsTest
    static void testBuildAndSendEnvelope_NoEnvelopeTemplateOnDocTemplate() {
        // Document template with no Envelope_Template__c
        Document_Template__c docTmpl = new Document_Template__c(
            Name = 'Doc w/out EnvTemplate'
            // Envelope_Template__c intentionally left null
        );
        insert docTmpl;

        Proposal__c parent = createProposal(true, docTmpl.Id);
        Envelope__c env = createEnvelopeWithParent(parent);

        SignatureApiEnvelopeBuilderService.BuildContext ctx =
            new SignatureApiEnvelopeBuilderService.BuildContext(env.Id, false);

        Test.startTest();
        SignatureApiEnvelopeBuilderService.BuildResult result =
            SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);
        Test.stopTest();

        System.assertNotEquals(null, result.errorMessage);
        System.assert(
            result.errorMessage.contains('No Envelope Template linked to this Document Template.'),
            'Should report missing envelope template'
        );
    }

    @IsTest
    static void testBuildAndSendEnvelope_NoDocumentSourceConfigured() {
        // Parent with Document_Template__c but no CV Id and no Document_URL__c
        Envelope_Template__c envTmpl = createEnvelopeTemplate();
        Document_Template__c docTmpl = createDocumentTemplate(envTmpl.Id);

        Proposal__c parent = new Proposal__c(
            Document_Template__c = docTmpl.Id
            // Document_URL__c left null on purpose
        );
        insert parent;

        Envelope__c env = createEnvelopeWithParent(parent);

        SignatureApiEnvelopeBuilderService.BuildContext ctx =
            new SignatureApiEnvelopeBuilderService.BuildContext(env.Id, false);

        Test.startTest();
        SignatureApiEnvelopeBuilderService.BuildResult result =
            SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);
        Test.stopTest();

        System.assertNotEquals(null, result.errorMessage);
        System.assert(
            result.errorMessage.contains('No document source configured.'),
            'Should require either ContentVersion Id or Document_URL__c'
        );
    }

    @IsTest
    static void testBuildAndSendEnvelope_InvalidEnvelopeId() {
        // Envelope Id that doesn't exist -> SOQL "no rows" -> caught
        Id bogusEnvId = 'a0B000000000001AAA'; // well-formed but not real

        SignatureApiEnvelopeBuilderService.BuildContext ctx =
            new SignatureApiEnvelopeBuilderService.BuildContext(bogusEnvId, false);

        Test.startTest();
        SignatureApiEnvelopeBuilderService.BuildResult result =
            SignatureApiEnvelopeBuilderService.buildAndSendEnvelope(ctx);
        Test.stopTest();

        System.assertNotEquals(null, result.errorMessage, 'Error expected for invalid envelope id');
    }
}
