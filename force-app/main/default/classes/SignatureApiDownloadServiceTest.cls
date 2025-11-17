@IsTest
private class SignatureApiDownloadServiceTest {

    // --------------------------------------------------------
    // Test data helpers
    // --------------------------------------------------------

    private static Proposal__c createProposal() {
        Proposal__c p = new Proposal__c(
        );
        insert p;
        return p;
    }

    private static Envelope__c createEnvelopeWithParent(Proposal__c parent) {
        Envelope__c env = new Envelope__c(
            Envelope_Id__c        = 'env-123',
            Parent_Record_Id__c   = parent.Id,
            Parent_Record_Type__c = 'Proposal__c'
        );
        insert env;
        return env;
    }

    // --------------------------------------------------------
    // HTTP mocks for different scenarios
    // --------------------------------------------------------

    // Full happy-path mock
    private class MultiStepSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            HttpResponse res = new HttpResponse();

            if (endpoint.contains('/v1/envelopes/') && endpoint.contains('/deliverables')) {
                // List deliverables
                String body =
                    '{' +
                        '"data": [' +
                            '{"id": "deliv-1", "type": "sealed_document"},' +
                            '{"id": "deliv-2", "type": "other"}' +
                        ']' +
                    '}';
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody(body);
                return res;
            } else if (endpoint.contains('/v1/deliverables/')) {
                // Metadata
                String body =
                    '{' +
                        '"id": "deliv-1",' +
                        '"url": "callout:SignatureApi/file/deliv-1.pdf"' +
                    '}';
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody(body);
                return res;
            } else {
                // File download
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/pdf');
                res.setBody('FAKE_PDF_BYTES');
                return res;
            }
        }
    }

    // Non-2xx on the deliverables list
    private class ListErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/v1/envelopes/')) {
                res.setStatusCode(500);
                res.setStatus('500 Internal Server Error');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"error":"boom"}');
                return res;
            }
            res.setStatusCode(500);
            res.setStatus('500 Internal Server Error');
            res.setBody('{}');
            return res;
        }
    }

    // Empty deliverables list
    private class ListEmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/v1/envelopes/')) {
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"data": []}');
                return res;
            }
            res.setStatusCode(200);
            res.setStatus('200 OK');
            res.setBody('{}');
            return res;
        }
    }

    // Metadata call non-2xx
    private class MetadataErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint();
            if (endpoint.contains('/v1/envelopes/')) {
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"data":[{"id":"deliv-1","type":"sealed_document"}]}');
                return res;
            } else if (endpoint.contains('/v1/deliverables/')) {
                res.setStatusCode(404);
                res.setStatus('404 Not Found');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"error":"not found"}');
                return res;
            }
            res.setStatusCode(500);
            res.setStatus('500 Internal Server Error');
            res.setBody('{}');
            return res;
        }
    }

    // Metadata missing download URL
    private class MetadataMissingUrlMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint();
            if (endpoint.contains('/v1/envelopes/')) {
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"data":[{"id":"deliv-1","type":"sealed_document"}]}');
                return res;
            } else if (endpoint.contains('/v1/deliverables/')) {
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"id":"deliv-1"}'); // no url
                return res;
            }
            res.setStatusCode(200);
            res.setStatus('200 OK');
            res.setBody('{}');
            return res;
        }
    }

    // Download error (non-200 on the file download)
    private class DownloadErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint();
            if (endpoint.contains('/v1/envelopes/')) {
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"data":[{"id":"deliv-1","type":"sealed_document"}]}');
                return res;
            } else if (endpoint.contains('/v1/deliverables/')) {
                res.setStatusCode(200);
                res.setStatus('200 OK');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"id":"deliv-1","url":"callout:SignatureApi/file/deliv-1.pdf"}');
                return res;
            } else {
                // File download fails
                res.setStatusCode(502);
                res.setStatus('502 Bad Gateway');
                res.setHeader('Content-Type', 'application/json');
                res.setBody('{"error":"upstream error"}');
                return res;
            }
        }
    }

    // Mock that throws to hit the catch(Exception) path
    private class ExceptionMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new CalloutException('Simulated callout failure');
        }
    }

    // --------------------------------------------------------
    // Parameter validation
    // --------------------------------------------------------

    @IsTest
    static void testDownloadFinalDeliverable_MissingEnvelopeId() {
        Proposal__c parent = createProposal();

        SignatureApiDownloadService.DownloadResult res =
            SignatureApiDownloadService.downloadFinalDeliverable(
                null,
                parent.Id,
                'Test File'
            );

        System.assertEquals(
            'Envelope Id is required.',
            res.error
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverable_MissingParentRecordId() {
        SignatureApiDownloadService.DownloadResult res =
            SignatureApiDownloadService.downloadFinalDeliverable(
                'env-xyz',
                null,
                'Test File'
            );

        System.assertEquals(
            'Parent Record Id is required.',
            res.error
        );
        System.assertEquals(null, res.contentVersionId);
    }

    // --------------------------------------------------------
    // Full success path
    // --------------------------------------------------------

    @IsTest
    static void testDownloadFinalDeliverable_Success() {
        Proposal__c parent = createProposal();

        Test.setMock(HttpCalloutMock.class, new MultiStepSuccessMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-123',
            parent.Id,
            null // force default "Signed Document"
        );
        Test.stopTest();

        System.assertEquals(null, res.error, 'No error expected on full success path');
        System.assertNotEquals(null, res.contentVersionId, 'ContentVersion Id should be returned');

        ContentVersion cv = [
            SELECT Id, Title, FirstPublishLocationId
            FROM ContentVersion
            WHERE Id = :res.contentVersionId
        ];
        System.assertEquals(
            'Signed Document',
            cv.Title,
            'Default title should be used when fileName is blank'
        );
        System.assertEquals(
            parent.Id,
            cv.FirstPublishLocationId,
            'File should be attached to the parent record'
        );
    }

    // --------------------------------------------------------
    // Error branches inside main logic
    // --------------------------------------------------------

    @IsTest
    static void testDownloadFinalDeliverable_ListError() {
        Proposal__c parent = createProposal();
        Test.setMock(HttpCalloutMock.class, new ListErrorMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-err',
            parent.Id,
            'File'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.error, 'Error should be set for list failure');
        System.assert(
            res.error.contains('Deliverables list failed:'),
            'Error message should indicate deliverables list failure'
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverable_ListEmpty() {
        Proposal__c parent = createProposal();
        Test.setMock(HttpCalloutMock.class, new ListEmptyMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-empty',
            parent.Id,
            'File'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.error, 'Error should be set for empty list');
        System.assert(
            res.error.contains('No deliverables found for envelope env-empty'),
            'Error should mention no deliverables for this envelope'
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverable_MetadataError() {
        Proposal__c parent = createProposal();
        Test.setMock(HttpCalloutMock.class, new MetadataErrorMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-meta',
            parent.Id,
            'File'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.error);
        System.assert(
            res.error.contains('Deliverable fetch failed:'),
            'Error should indicate metadata fetch failure'
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverable_MetadataMissingUrl() {
        Proposal__c parent = createProposal();
        Test.setMock(HttpCalloutMock.class, new MetadataMissingUrlMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-nourl',
            parent.Id,
            'File'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.error);
        System.assert(
            res.error.contains('Deliverable metadata did not include a download URL.'),
            'Error should mention missing download URL'
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverable_DownloadError() {
        Proposal__c parent = createProposal();
        Test.setMock(HttpCalloutMock.class, new DownloadErrorMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-dlerr',
            parent.Id,
            'File'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.error);
        System.assert(
            res.error.contains('File download failed:'),
            'Error should indicate file download failure'
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverable_UnhandledException() {
        Proposal__c parent = createProposal();
        Test.setMock(HttpCalloutMock.class, new ExceptionMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverable(
            'env-ex',
            parent.Id,
            'File'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.error, 'Error should be set when an exception occurs');
        System.assert(
            res.error.contains('Simulated callout failure'),
            'Exception message should be surfaced in error'
        );
        System.assertEquals(null, res.contentVersionId);
    }

    // --------------------------------------------------------
    // Overload: downloadFinalDeliverableForEnvelopeRecord
    // --------------------------------------------------------

    @IsTest
    static void testDownloadFinalDeliverableForEnvelopeRecord_NullEnv() {
        SignatureApiDownloadService.DownloadResult res =
            SignatureApiDownloadService.downloadFinalDeliverableForEnvelopeRecord(
                null,
                'File'
            );

        System.assertEquals(
            'Envelope record is null.',
            res.error
        );
        System.assertEquals(null, res.contentVersionId);
    }

    @IsTest
    static void testDownloadFinalDeliverableForEnvelopeRecord_UsesEnvNameAsDefaultFileName() {
        Proposal__c parent = createProposal();
        Envelope__c env = createEnvelopeWithParent(parent);

        env = [
            SELECT Id, Name, Envelope_Id__c, Parent_Record_Id__c
            FROM Envelope__c
            WHERE Id = :env.Id
        ];

        Test.setMock(HttpCalloutMock.class, new MultiStepSuccessMock());

        SignatureApiDownloadService.DownloadResult res;
        Test.startTest();
        res = SignatureApiDownloadService.downloadFinalDeliverableForEnvelopeRecord(
            env,
            null // force service to use env.Name as filename
        );
        Test.stopTest();

        System.assertEquals(null, res.error);
        System.assertNotEquals(null, res.contentVersionId);

        ContentVersion cv = [
            SELECT Id, Title, FirstPublishLocationId
            FROM ContentVersion
            WHERE Id = :res.contentVersionId
        ];
        System.assertEquals(
            env.Name,
            cv.Title,
            'When fileName is blank, env.Name should be used'
        );
        System.assertEquals(
            parent.Id,
            cv.FirstPublishLocationId,
            'File should be attached to the envelope parent record'
        );
    }
}
