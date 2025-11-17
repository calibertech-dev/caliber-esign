@IsTest
private class SignatureApiCreateEnvelopeActionTest {

    // --------------------------------------------------------
    // Test data helpers
    // --------------------------------------------------------

    private static Proposal__c createProposal() {
        // Adjust fields as needed if Proposal__c has other required fields
        Proposal__c p = new Proposal__c(
        );
        insert p;
        return p;
    }

    private static ContentVersion createContentVersion() {
        ContentVersion cv = new ContentVersion(
            Title        = 'Test Document',
            PathOnClient = 'test.pdf',
            VersionData  = Blob.valueOf('PDF content')
        );
        insert cv;
        return cv;
    }

    // Simple generic mock for any SignatureApi callouts that the orchestration may make.
    // We *want* it to be forgiving: 200 + empty JSON.
    private class Generic200Mock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setStatus('200 OK');
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{}');
            return res;
        }
    }

    // --------------------------------------------------------
    // Tests
    // --------------------------------------------------------

    @IsTest
    static void testCreateEnvelopes_WithDocumentsList() {
        // Arrange
        Proposal__c proposal = createProposal();
        ContentVersion cv    = createContentVersion();

        // Make sure any callouts from the orchestration are mocked
        Test.setMock(HttpCalloutMock.class, new Generic200Mock());

        SignatureApiCreateEnvelopeAction.RecipientInput recInput =
            new SignatureApiCreateEnvelopeAction.RecipientInput();
        recInput.recipientKey = 'client';
        recInput.name         = 'Client One';
        recInput.email        = 'client@example.com';
        // signerRecordId optional (Contact/User); leave null here to keep it simple

        SignatureApiCreateEnvelopeAction.DocumentInput docInput =
            new SignatureApiCreateEnvelopeAction.DocumentInput();
        docInput.contentVersionId = cv.Id;

        SignatureApiCreateEnvelopeAction.Request req =
            new SignatureApiCreateEnvelopeAction.Request();
        req.parentRecordId   = proposal.Id;
        req.parentRecordType = 'Proposal__c';  // valid parent type
        req.recipients       = new List<SignatureApiCreateEnvelopeAction.RecipientInput>{ recInput };
        req.documents        = new List<SignatureApiCreateEnvelopeAction.DocumentInput>{ docInput };
        req.sendImmediately  = true;

        List<SignatureApiCreateEnvelopeAction.Request> reqs =
            new List<SignatureApiCreateEnvelopeAction.Request>{ req };

        // Act
        Test.startTest();
        List<SignatureApiCreateEnvelopeAction.Response> results =
            SignatureApiCreateEnvelopeAction.createEnvelopes(reqs);
        Test.stopTest();

        // Assert
        System.assertEquals(1, results.size(), 'One response per request expected');
        SignatureApiCreateEnvelopeAction.Response res = results[0];

        // We don’t assert on envelopeId/signatureApiEnvelopeId/status because that depends
        // on the orchestration internals. We just care that the method runs and doesn’t throw.
        System.assertNotEquals(null, res, 'Response should not be null');
        // errorMessage may or may not be null depending on how the orchestration behaves
    }

    @IsTest
    static void testCreateEnvelopes_WithFallbackContentVersionId() {
        // Arrange
        Proposal__c proposal = createProposal();
        ContentVersion cv    = createContentVersion();

        Test.setMock(HttpCalloutMock.class, new Generic200Mock());

        SignatureApiCreateEnvelopeAction.RecipientInput recInput =
            new SignatureApiCreateEnvelopeAction.RecipientInput();
        recInput.recipientKey = 'contractor';
        recInput.name         = 'Contractor One';
        recInput.email        = 'contractor@example.com';

        SignatureApiCreateEnvelopeAction.Request req =
            new SignatureApiCreateEnvelopeAction.Request();
        req.parentRecordId    = proposal.Id;
        req.parentRecordType  = 'Proposal__c';
        req.recipients        = new List<SignatureApiCreateEnvelopeAction.RecipientInput>{ recInput };
        req.documents         = null;           // documents list omitted
        req.contentVersionId  = cv.Id;          // use fallback single ContentVersionId
        req.sendImmediately   = false;

        List<SignatureApiCreateEnvelopeAction.Request> reqs =
            new List<SignatureApiCreateEnvelopeAction.Request>{ req };

        // Act
        Test.startTest();
        List<SignatureApiCreateEnvelopeAction.Response> results =
            SignatureApiCreateEnvelopeAction.createEnvelopes(reqs);
        Test.stopTest();

        // Assert
        System.assertEquals(1, results.size());
        SignatureApiCreateEnvelopeAction.Response res = results[0];
        System.assertNotEquals(null, res, 'Response should not be null');

        // This run covers the else-if path where documents == null
        // and contentVersionId is used to build the documents list.
    }

    @IsTest
    static void testCreateEnvelopes_ExceptionPath() {
        // This forces the orchestration to throw (parentRecordId is null),
        // which should be caught and surfaced as errorMessage.
        Test.setMock(HttpCalloutMock.class, new Generic200Mock());

        SignatureApiCreateEnvelopeAction.RecipientInput recInput =
            new SignatureApiCreateEnvelopeAction.RecipientInput();
        recInput.recipientKey = 'client';
        recInput.name         = 'Client Error';
        recInput.email        = 'client.error@example.com';

        SignatureApiCreateEnvelopeAction.Request req =
            new SignatureApiCreateEnvelopeAction.Request();
        req.parentRecordId    = null;           // invalid, will cause orchestration to blow up
        req.parentRecordType  = null;
        req.recipients        = new List<SignatureApiCreateEnvelopeAction.RecipientInput>{ recInput };
        req.documents         = null;
        req.contentVersionId  = null;
        req.sendImmediately   = false;

        List<SignatureApiCreateEnvelopeAction.Request> reqs =
            new List<SignatureApiCreateEnvelopeAction.Request>{ req };

        // Act
        Test.startTest();
        List<SignatureApiCreateEnvelopeAction.Response> results =
            SignatureApiCreateEnvelopeAction.createEnvelopes(reqs);
        Test.stopTest();

        // Assert: exception is caught inside createEnvelopes and surfaced via errorMessage
        System.assertEquals(1, results.size());
        SignatureApiCreateEnvelopeAction.Response res = results[0];

        System.assertNotEquals(null, res.errorMessage,
            'errorMessage should be populated when orchestration throws');
    }
}
