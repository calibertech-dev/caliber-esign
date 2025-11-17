@IsTest
private class SignatureApiDownloadActionTest {

    // --------------------------------------------------------
    // Test data helper
    // --------------------------------------------------------

    // Use Proposal__c as a valid parent type.
    // Add more required fields if your org needs them.
    private static Proposal__c createProposal() {
        Proposal__c p = new Proposal__c(
        );
        insert p;
        return p;
    }

    // --------------------------------------------------------
    // Tests
    // --------------------------------------------------------

    @IsTest
    static void testDownloadCompleted_NullRequestElement() {
        // List includes a null element to hit the "req == null" branch
        List<SignatureApiDownloadAction.DownloadRequest> reqs =
            new List<SignatureApiDownloadAction.DownloadRequest>{ null };

        Test.startTest();
        List<SignatureApiDownloadAction.DownloadResponse> results =
            SignatureApiDownloadAction.downloadCompleted(reqs);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one response per list element');
        SignatureApiDownloadAction.DownloadResponse resp = results[0];

        System.assertEquals(
            'Request is null.',
            resp.error,
            'Null request should surface a clear error'
        );
        System.assertEquals(
            null,
            resp.contentVersionId,
            'No ContentVersion should be created for null requests'
        );
    }

    @IsTest
    static void testDownloadCompleted_BlankEnvelopeId_ServiceValidationError() {
        // This uses the validation branch in SignatureApiDownloadService:
        // if (String.isBlank(envelopeId)) { result.error = 'Envelope Id is required.'; }
        Proposal__c parent = createProposal();

        SignatureApiDownloadAction.DownloadRequest dr =
            new SignatureApiDownloadAction.DownloadRequest();
        dr.envelopeId      = '';         // invalid → service should set validation error
        dr.fileName        = 'Bad File';
        dr.parentRecordId  = parent.Id;  // also exercises parentType resolution

        List<SignatureApiDownloadAction.DownloadRequest> reqs =
            new List<SignatureApiDownloadAction.DownloadRequest>{ dr };

        Test.startTest();
        List<SignatureApiDownloadAction.DownloadResponse> results =
            SignatureApiDownloadAction.downloadCompleted(reqs);
        Test.stopTest();

        System.assertEquals(1, results.size());
        SignatureApiDownloadAction.DownloadResponse resp = results[0];

        System.assertEquals(
            'Envelope Id is required.',
            resp.error,
            'Expected service validation error for blank envelope id'
        );
        System.assertEquals(
            null,
            resp.contentVersionId,
            'No ContentVersion should be created when validation fails'
        );
    }

    @IsTest
    static void testDownloadCompleted_NoDeliverablesError() {
        // This uses a non-blank envelopeId that, in your current implementation,
        // results in some "no deliverables" style error from the download service.
        Proposal__c parent = createProposal();

        SignatureApiDownloadAction.DownloadRequest dr =
            new SignatureApiDownloadAction.DownloadRequest();
        dr.envelopeId      = 'env-ext-123';
        dr.fileName        = 'Signed Agreement';
        dr.parentRecordId  = parent.Id;

        List<SignatureApiDownloadAction.DownloadRequest> reqs =
            new List<SignatureApiDownloadAction.DownloadRequest>{ dr };

        Test.startTest();
        List<SignatureApiDownloadAction.DownloadResponse> results =
            SignatureApiDownloadAction.downloadCompleted(reqs);
        Test.stopTest();

        System.assertEquals(1, results.size());
        SignatureApiDownloadAction.DownloadResponse resp = results[0];

        // We only need to know that an error was surfaced and no file was created.
        System.assertNotEquals(
            null,
            resp.error,
            'Error should be populated when the service finds no deliverables'
        );
        System.assertEquals(
            null,
            resp.contentVersionId,
            'No ContentVersion should be created when the service cannot find deliverables'
        );
    }

}
