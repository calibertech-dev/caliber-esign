@IsTest
private class SignatureApiCreateCeremonyActionTest {

    // --------------------------------------------------------
    // Test data helpers
    // --------------------------------------------------------

    // Use Contract__c as the valid parent type for Envelope__c
    private static Contract__c createContract() {
        // Assuming Contract__c has a standard Name text field (not autonumber).
        Contract__c c = new Contract__c(
        );
        insert c;
        return c;
    }

    private static Envelope__c createEnvelopeWithParent() {
        Contract__c contract = createContract();

        Envelope__c env = new Envelope__c(
            // Name is autonumber on Envelope__c, so DO NOT set it
            Envelope_Id__c       = 'env-ext-123',
            Parent_Record_Id__c  = contract.Id,
            Parent_Record_Type__c= 'Contract__c' // valid picklist value
        );
        insert env;
        return env;
    }

    private static Envelope_Recipient__c createRecipient(
        Id envelopeId,
        Boolean withRecipientExternalId
    ) {
        // Name is autonumber on Envelope_Recipient__c, so DO NOT set it
        Envelope_Recipient__c rec = new Envelope_Recipient__c(
            Envelope__c = envelopeId
        );
        if (withRecipientExternalId) {
            rec.Recipient_Id__c = 'rec-ext-123';
        }
        // Any Contact/User-related field is left alone here; this action doesn’t use it
        insert rec;
        return rec;
    }

    // --------------------------------------------------------
    // HTTP mocks for the underlying SignatureApiCeremonyService
    // --------------------------------------------------------

    // Happy-path mock: 200 with a URL
    private class CeremonySuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setStatus('200 OK');
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"url":"https://example.com/ceremony/abc"}');
            return res;
        }
    }

    // 200 but no URL -> CeremonyService will set error and not update the record
    private class CeremonyNoUrlMock implements HttpCalloutMock {
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
    static void testCreateCeremonies_Success() {
        // Arrange valid parent + envelope + recipient
        Envelope__c env = createEnvelopeWithParent();
        Envelope_Recipient__c rec = createRecipient(env.Id, true);

        // Mock SignatureApiCeremonyService HTTP callout
        Test.setMock(HttpCalloutMock.class, new CeremonySuccessMock());

        SignatureApiCreateCeremonyAction.CeremonyRequest reqDto =
            new SignatureApiCreateCeremonyAction.CeremonyRequest();
        reqDto.envelopeRecipientId = rec.Id;

        List<SignatureApiCreateCeremonyAction.CeremonyRequest> reqs =
            new List<SignatureApiCreateCeremonyAction.CeremonyRequest>{ reqDto };

        // Act
        Test.startTest();
        List<SignatureApiCreateCeremonyAction.CeremonyResponse> results =
            SignatureApiCreateCeremonyAction.createCeremonies(reqs);
        Test.stopTest();

        // Assert
        System.assertEquals(1, results.size(), 'Should return one response per request');
        SignatureApiCreateCeremonyAction.CeremonyResponse resp = results[0];

        System.assertEquals(rec.Id, resp.envelopeRecipientId, 'Envelope recipient id should echo input');
        System.assertEquals(null, resp.error, 'No error expected on success');
        System.assertNotEquals(null, resp.ceremonyUrl, 'Ceremony URL should be populated on success');
    }

    @IsTest
    static void testCreateCeremonies_ServiceReturnsError_WarnBranch() {
        // Arrange valid parent + envelope + recipient
        Envelope__c env = createEnvelopeWithParent();
        Envelope_Recipient__c rec = createRecipient(env.Id, true);

        // Mock: Ceremony service returns 200 but with no URL -> error inside service
        Test.setMock(HttpCalloutMock.class, new CeremonyNoUrlMock());

        SignatureApiCreateCeremonyAction.CeremonyRequest reqDto =
            new SignatureApiCreateCeremonyAction.CeremonyRequest();
        reqDto.envelopeRecipientId = rec.Id;

        List<SignatureApiCreateCeremonyAction.CeremonyRequest> reqs =
            new List<SignatureApiCreateCeremonyAction.CeremonyRequest>{ reqDto };

        // Act
        Test.startTest();
        List<SignatureApiCreateCeremonyAction.CeremonyResponse> results =
            SignatureApiCreateCeremonyAction.createCeremonies(reqs);
        Test.stopTest();

        // Assert
        System.assertEquals(1, results.size());
        SignatureApiCreateCeremonyAction.CeremonyResponse resp = results[0];

        System.assertEquals(rec.Id, resp.envelopeRecipientId);
        System.assertEquals(null, resp.ceremonyUrl, 'No URL should be returned when service fails');
        System.assertNotEquals(null, resp.error, 'Error should bubble up from CeremonyService');

        // This scenario exercises the WARN logEvent branch (serviceRes.error != null).
    }

    @IsTest
    static void testCreateCeremonies_UnhandledException_CaughtAndReturned() {
        // Force the SOQL in the action to throw "no rows for assignment to SObject"
        // by using a fake Id that matches no Envelope_Recipient__c.
        // Using an arbitrary valid-looking Id string is enough.
        Id bogusRecipientId = '001000000000000AAA';

        SignatureApiCreateCeremonyAction.CeremonyRequest reqDto =
            new SignatureApiCreateCeremonyAction.CeremonyRequest();
        reqDto.envelopeRecipientId = bogusRecipientId;

        List<SignatureApiCreateCeremonyAction.CeremonyRequest> reqs =
            new List<SignatureApiCreateCeremonyAction.CeremonyRequest>{ reqDto };

        // Act
        Test.startTest();
        List<SignatureApiCreateCeremonyAction.CeremonyResponse> results =
            SignatureApiCreateCeremonyAction.createCeremonies(reqs);
        Test.stopTest();

        // Assert: exception is caught inside the action, not thrown to the test
        System.assertEquals(1, results.size());
        SignatureApiCreateCeremonyAction.CeremonyResponse resp = results[0];

        System.assertEquals(bogusRecipientId, resp.envelopeRecipientId);
        System.assertNotEquals(null, resp.error, 'Error message should be set from caught exception');
    }
}
