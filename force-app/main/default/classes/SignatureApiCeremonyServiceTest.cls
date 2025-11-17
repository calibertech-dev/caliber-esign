@IsTest
private class SignatureApiCeremonyServiceTest {

    // --------------------------
    // Test data helpers
    // --------------------------

    private static Envelope__c createEnvelope() {
        Envelope__c env = new Envelope__c(
            Envelope_Id__c = 'env-ext-123',
            Parent_Record_Id__c = null,
            Parent_Record_Type__c = null
        );
        insert env;
        return env;
    }

    private static Envelope_Recipient__c createRecipient(
        Id envelopeId,
        Boolean withRecipientId
    ) {
        Envelope_Recipient__c rec = new Envelope_Recipient__c(
            Envelope__c = envelopeId
        );
        if (withRecipientId) {
            rec.Recipient_Id__c = 'rec-ext-123';
        }
        insert rec;
        return rec;
    }

    // --------------------------
    // HTTP mocks
    // --------------------------

    // 200 with URL in body
    private class CeremonySuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"url":"https://example.com/ceremony/123"}');
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    // 200 but no URL in body
    private class CeremonyNoUrlMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // No "url" key
            res.setBody('{}');
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    // Non-2xx response (error)
    private class CeremonyErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"Internal server error"}');
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    // --------------------------
    // Tests
    // --------------------------

    @IsTest
    static void testCreateCeremony_Success() {
        Envelope__c env = createEnvelope();
        Envelope_Recipient__c rec = createRecipient(env.Id, true);

        Test.setMock(HttpCalloutMock.class, new CeremonySuccessMock());

        Test.startTest();
        SignatureApiCeremonyService.CeremonyResult result =
            SignatureApiCeremonyService.createCeremonyForRecipient(rec.Id);
        Test.stopTest();

        // Reload recipient to check DML
        rec = [
            SELECT Ceremony_URL__c
            FROM Envelope_Recipient__c
            WHERE Id = :rec.Id
        ];

        System.assertEquals(rec.Id, result.envelopeRecipientId, 'Envelope recipient id should echo input');
        System.assertEquals(null, result.error, 'No error expected on success');
        System.assertNotEquals(null, result.ceremonyUrl, 'Ceremony URL should be set in result');
        System.assertEquals(result.ceremonyUrl, rec.Ceremony_URL__c, 'Ceremony URL should be persisted on recipient');
    }

    @IsTest
    static void testCreateCeremony_MissingRecipientId() {
        Envelope__c env = createEnvelope();
        // Recipient without Recipient_Id__c -> hits "missing recipient id" branch
        Envelope_Recipient__c rec = createRecipient(env.Id, false);

        // No callout should be made in this scenario, so no mock needed

        Test.startTest();
        SignatureApiCeremonyService.CeremonyResult result =
            SignatureApiCeremonyService.createCeremonyForRecipient(rec.Id);
        Test.stopTest();

        System.assertEquals(rec.Id, result.envelopeRecipientId);
        System.assertNotEquals(null, result.error, 'Error should be set when Recipient_Id__c is missing');
        System.assert(
            result.error.contains('missing on Envelope_Recipient__c') ||
            result.error.toLowerCase().contains('missing'),
            'Error message should mention missing recipient id'
        );

        // Ceremony URL should not be set
        rec = [
            SELECT Ceremony_URL__c
            FROM Envelope_Recipient__c
            WHERE Id = :rec.Id
        ];
        System.assertEquals(null, rec.Ceremony_URL__c, 'Ceremony URL should remain null on missing recipient id');
    }

    @IsTest
    static void testCreateCeremony_HttpError() {
        Envelope__c env = createEnvelope();
        Envelope_Recipient__c rec = createRecipient(env.Id, true);

        Test.setMock(HttpCalloutMock.class, new CeremonyErrorMock());

        Test.startTest();
        SignatureApiCeremonyService.CeremonyResult result =
            SignatureApiCeremonyService.createCeremonyForRecipient(rec.Id);
        Test.stopTest();

        System.assertEquals(rec.Id, result.envelopeRecipientId);
        System.assertNotEquals(null, result.error, 'Error should be populated on HTTP failure');
        System.assert(
            result.error.startsWith('Ceremony creation failed:'),
            'Error message should include HTTP failure prefix'
        );

        rec = [
            SELECT Ceremony_URL__c
            FROM Envelope_Recipient__c
            WHERE Id = :rec.Id
        ];
        System.assertEquals(null, rec.Ceremony_URL__c, 'Ceremony URL should not be updated on HTTP error');
    }

    @IsTest
    static void testCreateCeremony_SuccessNoUrl() {
        Envelope__c env = createEnvelope();
        Envelope_Recipient__c rec = createRecipient(env.Id, true);

        Test.setMock(HttpCalloutMock.class, new CeremonyNoUrlMock());

        Test.startTest();
        SignatureApiCeremonyService.CeremonyResult result =
            SignatureApiCeremonyService.createCeremonyForRecipient(rec.Id);
        Test.stopTest();

        System.assertEquals(rec.Id, result.envelopeRecipientId);
        System.assertEquals(
            'Ceremony created but no URL returned from SignatureApi.',
            result.error,
            'Error should describe missing URL from response'
        );
        System.assertEquals(null, result.ceremonyUrl, 'Ceremony URL should not be set in result');

        rec = [
            SELECT Ceremony_URL__c
            FROM Envelope_Recipient__c
            WHERE Id = :rec.Id
        ];
        System.assertEquals(null, rec.Ceremony_URL__c, 'Ceremony URL should not be persisted when missing in response');
    }

    @IsTest
    static void testCreateCeremony_UnhandledExceptionPath() {
        // Force the SOQL query to throw "List has no rows for assignment to SObject"
        // by passing null as the Id. That should drop into the catch block and log.
        Test.startTest();
        SignatureApiCeremonyService.CeremonyResult result =
            SignatureApiCeremonyService.createCeremonyForRecipient(null);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should still be returned on exception');
        System.assertNotEquals(null, result.error, 'Error should be set when an unhandled exception occurs');
    }
}
