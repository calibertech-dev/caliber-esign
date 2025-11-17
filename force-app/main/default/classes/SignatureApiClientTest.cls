@IsTest
private class SignatureApiClientTest {

    // --------------------------------------------------------
    // Test HTTP mocks
    // --------------------------------------------------------

    /**
     * 201 response with full envelope + recipients payload.
     * Also asserts that buildRequest() constructed the request correctly.
     */
    private class EnvelopeCreateSuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            // Basic sanity checks on the request shape
            System.assertEquals('POST', req.getMethod(), 'Method should be POST');
            System.assertEquals(
                'callout:SignatureApi/v1/envelopes',
                req.getEndpoint(),
                'Endpoint should be built from Named Credential + path'
            );
            System.assertEquals(
                'application/json',
                req.getHeader('Content-Type'),
                'Content-Type header should be application/json'
            );
            System.assertEquals(
                'application/json',
                req.getHeader('Accept'),
                'Accept header should be application/json'
            );
            System.assertNotEquals(
                null,
                req.getBody(),
                'Request body should not be null'
            );

            // Response body includes two recipients:
            // - one with "url"
            // - one with "ceremony_url"
            // so we hit both branches of the ternary in createEnvelope().
            String body =
                '{' +
                    '"id": "env-123",' +
                    '"status": "created",' +
                    '"recipients": [' +
                        '{' +
                            '"id": "rec-1",' +
                            '"key": "client",' +
                            '"status": "pending",' +
                            '"url": "https://example.com/c1",' +
                            '"email": "client@example.com",' +
                            '"name": "Client One"' +
                        '},' +
                        '{' +
                            '"id": "rec-2",' +
                            '"key": "contractor",' +
                            '"status": "pending",' +
                            '"ceremony_url": "https://example.com/c2",' +
                            '"email": "contractor@example.com",' +
                            '"name": "Contractor Two"' +
                        '}' +
                    ']' +
                '}';

            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setStatus('201 Created');
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            return res;
        }
    }

    /**
     * Non-2xx response to trigger send()'s error logging and CalloutException.
     */
    private class EnvelopeCreateErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setStatus('500 Internal Server Error');
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"error":"Something blew up"}');
            return res;
        }
    }

    /**
     * Mock that throws from respond(), simulating Http.send() throwing.
     * This exercises the catch(Exception) path inside send(), and then
     * the catch(Exception) inside createEnvelope().
     */
    private class EnvelopeCreateThrowingMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            // Simulate some unexpected platform error during the callout
            throw new CalloutException('Simulated send failure');
        }
    }

    // --------------------------------------------------------
    // Tests
    // --------------------------------------------------------

    @IsTest
    static void testCreateEnvelope_Success() {
        // Arrange
        Test.setMock(HttpCalloutMock.class, new EnvelopeCreateSuccessMock());

        Map<String, Object> payload = new Map<String, Object>{
            'name' => 'Test Envelope',
            'foo'  => 'bar'
        };

        // Act
        Test.startTest();
        SignatureApiClient.EnvelopeCreateResponse res =
            SignatureApiClient.createEnvelope(payload);
        Test.stopTest();

        // Assert envelope fields
        System.assertNotEquals(null, res, 'Response should not be null');
        System.assertEquals('env-123', res.id, 'Envelope id should be parsed from response');
        System.assertEquals('created', res.status, 'Envelope status should be parsed from response');

        // Assert recipients list
        System.assertNotEquals(null, res.recipients, 'Recipients list should be initialized');
        System.assertEquals(2, res.recipients.size(), 'Should parse two recipients');

        SignatureApiClient.RecipientInfo r1 = res.recipients[0];
        SignatureApiClient.RecipientInfo r2 = res.recipients[1];

        // First recipient uses "url"
        System.assertEquals('rec-1', r1.id);
        System.assertEquals('client', r1.key);
        System.assertEquals('pending', r1.status);
        System.assertEquals('https://example.com/c1', r1.ceremonyUrl);
        System.assertEquals('client@example.com', r1.email);
        System.assertEquals('Client One', r1.name);

        // Second recipient uses "ceremony_url"
        System.assertEquals('rec-2', r2.id);
        System.assertEquals('contractor', r2.key);
        System.assertEquals('pending', r2.status);
        System.assertEquals('https://example.com/c2', r2.ceremonyUrl);
        System.assertEquals('contractor@example.com', r2.email);
        System.assertEquals('Contractor Two', r2.name);
    }

    @IsTest
    static void testCreateEnvelope_Non2xxResponse_ThrowsCalloutException() {
        // Arrange
        Test.setMock(HttpCalloutMock.class, new EnvelopeCreateErrorMock());

        Map<String, Object> payload = new Map<String, Object>{
            'name' => 'Bad Envelope'
        };

        // Act
        Exception captured;
        Test.startTest();
        try {
            SignatureApiClient.createEnvelope(payload);
        } catch (Exception ex) {
            captured = ex;
        }
        Test.stopTest();

        // Assert
        System.assertNotEquals(null, captured, 'Expected an exception to be thrown');
        System.assert(captured instanceof CalloutException,
            'Expected a CalloutException from non-2xx response');

        System.assert(
            captured.getMessage().contains('SignatureApi call failed:'),
            'Exception message should include "SignatureApi call failed" prefix'
        );
    }

    @IsTest
    static void testCreateEnvelope_HttpSendThrows_ExceptionPath() {
        // Arrange
        Test.setMock(HttpCalloutMock.class, new EnvelopeCreateThrowingMock());

        Map<String, Object> payload = new Map<String, Object>{
            'name' => 'Envelope causing send failure'
        };

        // Act
        Exception captured;
        Test.startTest();
        try {
            SignatureApiClient.createEnvelope(payload);
        } catch (Exception ex) {
            captured = ex;
        }
        Test.stopTest();

        // Assert
        System.assertNotEquals(null, captured, 'Expected exception to propagate through createEnvelope');
        System.assert(
            captured.getMessage().contains('Simulated send failure'),
            'Should preserve original Http.send() exception message'
        );
    }
}
