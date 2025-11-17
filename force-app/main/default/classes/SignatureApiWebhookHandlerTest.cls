@IsTest(SeeAllData=false)
private class SignatureApiWebhookHandlerTest {

    // Helper to build a RestRequest/RestResponse pair
    private static void setupRestContext(String body) {
        RestRequest req  = new RestRequest();
        RestResponse res = new RestResponse();

        req.requestUri  = '/services/apexrest/signatureapi/webhook';
        req.httpMethod  = 'POST';
        req.requestBody = (body != null) ? Blob.valueOf(body) : null;

        RestContext.request  = req;
        RestContext.response = res;
    }

    @IsTest
    static void testHandleWebhook_HappyPath_InsertsEvent() {
        // Build a valid SignatureApi-style payload
        Map<String, Object> data = new Map<String, Object>();
        data.put('envelope_id',   'env_123');
        data.put('object_id',     'obj_456');
        data.put('recipient_key', 'client');
        data.put('status',        'completed');

        Map<String, Object> payload = new Map<String, Object>();
        payload.put('type', 'envelope.completed');
        payload.put('data', data);

        String body = JSON.serialize(payload);

        setupRestContext(body);

        // Do NOT wrap in startTest/stopTest → avoids running the Queueable
        SignatureApiWebhookHandler.handleWebhook();

        // Response should always be 200 / OK
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('OK', RestContext.response.responseBody.toString());

        // Envelope_Event__c should have been inserted
        List<Envelope_Event__c> events = [
            SELECT Id,
                   Event_Type__c,
                   Envelope_Id__c,
                   Object_Id__c,
                   Recipient_Key__c,
                   Status__c,
                   Raw_Payload__c,
                   Processing_Status__c
            FROM Envelope_Event__c
            WHERE Envelope_Id__c = 'env_123'
        ];

        System.assertEquals(1, events.size(), 'One event should be created for the webhook.');

        Envelope_Event__c evt = events[0];
        System.assertEquals('envelope.completed', evt.Event_Type__c);
        System.assertEquals('env_123', evt.Envelope_Id__c);
        System.assertEquals('obj_456', evt.Object_Id__c);
        System.assertEquals('client',  evt.Recipient_Key__c);
        System.assertEquals('completed', evt.Status__c);
        System.assertEquals('Received', evt.Processing_Status__c);
        System.assertNotEquals(null, evt.Raw_Payload__c, 'Raw payload should be stored.');
    }

    @IsTest
    static void testHandleWebhook_EmptyBody_LogsAndReturns_NoEvent() {
        // Simulate empty body (either null or empty string will hit the branch)
        setupRestContext('');

        Test.startTest();
        SignatureApiWebhookHandler.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('OK', RestContext.response.responseBody.toString());

        // No Envelope_Event__c records should be created
        Integer countEvents = [SELECT COUNT() FROM Envelope_Event__c];
        System.assertEquals(0, countEvents, 'Empty body should not create any Envelope_Event__c.');
    }

    @IsTest
    static void testHandleWebhook_InvalidJson_CreatesErrorEvent() {
        // Invalid JSON will cause JSON.deserializeUntyped to throw,
        // triggering the catch block and the fallback error event insert.
        String badBody = 'not-valid-json';

        setupRestContext(badBody);

        Test.startTest();
        SignatureApiWebhookHandler.handleWebhook();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('OK', RestContext.response.responseBody.toString());

        // One error event should be created
        List<Envelope_Event__c> events = [
            SELECT Id,
                   Event_Type__c,
                   Raw_Payload__c,
                   Error_Message__c,
                   Processing_Status__c
            FROM Envelope_Event__c
            WHERE Event_Type__c = 'webhook.error'
        ];

        System.assertEquals(1, events.size(), 'An error event should be recorded for invalid JSON.');

        Envelope_Event__c evt = events[0];
        System.assertEquals('webhook.error', evt.Event_Type__c);
        System.assertEquals('Failed', evt.Processing_Status__c);
        System.assertNotEquals(null, evt.Error_Message__c, 'Error message should be stored.');
        System.assertEquals(badBody, evt.Raw_Payload__c, 'Raw payload should match the bad JSON body.');
    }
}
