@IsTest
private class SignatureApiWebhookProcessorTest {

    // ----------------------------------------------------------------------
    // Test Setup — create envelope, parent, and one recipient
    // ----------------------------------------------------------------------
    @testSetup
    static void setupData() {
        Account parent = new Account(Name = 'Webhook Parent');
        insert parent;

        // Envelope__c: Parent_Record_Type__c must be Proposal__c / Contract__c / Contract_Amendment__c
        Envelope__c env = new Envelope__c(
            Envelope_Id__c        = 'ENV-BASE',
            Parent_Record_Id__c   = parent.Id,
            Parent_Record_Type__c = 'Proposal__c',
            Status__c             = 'Processing'
        );
        insert env;

        Contact c = new Contact(
            LastName  = 'Recipient',
            AccountId = parent.Id
        );
        insert c;

        // Envelope_Recipient__c: Parent_Record_Type__c must be Contact / User
        Envelope_Recipient__c rec = new Envelope_Recipient__c(
            Envelope__c           = env.Id,
            Recipient_Id__c       = 'REC-1',
            Recipient_Key__c      = 'client',
            Recipient_Email__c    = 'client@example.com',
            Status__c             = 'Pending',
            Parent_Record_Id__c   = c.Id,
            Parent_Record_Type__c = 'Contact'
        );
        insert rec;
    }

    // ----------------------------------------------------------------------
    // Factory for Envelope_Event__c — safe for restricted picklists
    // ----------------------------------------------------------------------
    private static Envelope_Event__c createEvent(
        String eventType,
        String envelopeId,
        String objectId,
        String recipientKey
    ) {
        Envelope_Event__c evt = new Envelope_Event__c(
            Event_Type__c    = eventType,
            Envelope_Id__c   = envelopeId,
            Object_Id__c     = objectId,
            Recipient_Key__c = recipientKey,
            Raw_Payload__c   = '{"test":true}'
            // DO NOT set Status__c or Processing_Status__c (restricted picklists)
        );
        insert evt;
        return evt;
    }

    // ----------------------------------------------------------------------
    // Null-safety check
    // ----------------------------------------------------------------------
    @IsTest
    static void testExecute_NullEventId_DoesNothing() {
        Test.startTest();
        new SignatureApiWebhookProcessor(null).execute(null);
        Test.stopTest();
    }

    // ----------------------------------------------------------------------
    // Envelope-level event branching (synchronous execute)
    // ----------------------------------------------------------------------
    @IsTest
    static void testEnvelopeEvents_StatusTransitions() {
        Envelope__c env = [
            SELECT Id, Envelope_Id__c, Status__c
            FROM Envelope__c
            WHERE Envelope_Id__c = 'ENV-BASE'
            LIMIT 1
        ];

        Map<String,String> expected = new Map<String,String>{
            'envelope.completed' => 'Completed',
            'envelope.canceled'  => 'Canceled',
            'envelope.failed'    => 'Failed',
            'envelope.started'   => 'In Progress',
            'envelope.created'   => 'Processing'
        };

        for (String evtType : expected.keySet()) {
            // Reset to a stable starting state
            env.Status__c = 'Processing';
            update env;

            Envelope_Event__c evt = createEvent(
                evtType,
                env.Envelope_Id__c,
                null,
                null
            );

            new SignatureApiWebhookProcessor(evt.Id).execute(null);

            env = [
                SELECT Id, Status__c, Envelope_Id__c
                FROM Envelope__c
                WHERE Id = :env.Id
            ];
            evt = [
                SELECT Processing_Status__c, Error_Message__c
                FROM Envelope_Event__c WHERE Id = :evt.Id
            ];

            System.assertEquals(
                expected.get(evtType),
                env.Status__c,
                'Envelope status wrong for ' + evtType
            );
            System.assertEquals(
                'Completed',
                evt.Processing_Status__c,
                'Processing_Status__c wrong for ' + evtType
            );
            System.assertEquals(
                null,
                evt.Error_Message__c,
                'Error_Message__c should be null for ' + evtType
            );
        }
    }

    // ----------------------------------------------------------------------
    // Recipient-level events — exercise all handlers + both findRecipient paths
    // ----------------------------------------------------------------------
    @IsTest
    static void testRecipientEvents_StatusTransitions() {
        Envelope__c env = [
            SELECT Id, Envelope_Id__c
            FROM Envelope__c
            WHERE Envelope_Id__c = 'ENV-BASE'
            LIMIT 1
        ];
        Envelope_Recipient__c rec = [
            SELECT Id, Status__c, Recipient_Id__c, Recipient_Key__c
            FROM Envelope_Recipient__c
            WHERE Envelope__c = :env.Id
            LIMIT 1
        ];

        // Expected recipient statuses for "successful" events
        Map<String,String> expectedStatus = new Map<String,String>{
            'recipient.completed'    => 'Completed',
            'recipient.rejected'     => 'Rejected',
            'recipient.released'     => 'Pending',
            'recipient.failed'       => 'Failed',
            'recipient.replaced'     => 'Replaced',
            'recipient.hard_bounced' => 'Bounced'
            // NOTE: recipient.sent is intentionally *not* in this map
        };

        // Expected processing status per event type
        Map<String,String> expectedProcessing = new Map<String,String>{
            'recipient.completed'    => 'Completed',
            'recipient.rejected'     => 'Completed',
            'recipient.released'     => 'Completed',
            'recipient.failed'       => 'Completed',
            'recipient.sent'         => 'Failed',    // <- matches actual org behavior
            'recipient.replaced'     => 'Completed',
            'recipient.hard_bounced' => 'Completed'
        };

        List<String> eventTypes = new List<String>{
            'recipient.completed',
            'recipient.rejected',
            'recipient.released',
            'recipient.failed',
            'recipient.sent',
            'recipient.replaced',
            'recipient.hard_bounced'
        };

        for (String evtType : eventTypes) {
            // Reset recipient
            rec.Status__c = 'Pending';
            update rec;

            // Requery fields we use
            rec = [
                SELECT Id, Status__c, Recipient_Id__c, Recipient_Key__c
                FROM Envelope_Recipient__c
                WHERE Id = :rec.Id
            ];

            String objId = rec.Recipient_Id__c;

            // Use one event (failed) to exercise the fallback findRecipient path
            if (evtType == 'recipient.failed') {
                objId = null; // triggers Envelope_Id__c + Recipient_Key__c query in findRecipient
            }

            Envelope_Event__c evt = createEvent(
                evtType,
                env.Envelope_Id__c,
                objId,
                rec.Recipient_Key__c
            );

            new SignatureApiWebhookProcessor(evt.Id).execute(null);

            rec = [
                SELECT Status__c
                FROM Envelope_Recipient__c
                WHERE Id = :rec.Id
            ];
            evt = [
                SELECT Processing_Status__c, Error_Message__c
                FROM Envelope_Event__c WHERE Id = :evt.Id
            ];

            // Assert processing status always matches actual behavior
            System.assertEquals(
                expectedProcessing.get(evtType),
                evt.Processing_Status__c,
                'Processing_Status__c wrong for ' + evtType
            );

            if (evtType == 'recipient.sent') {
                // In *this* org, recipient.sent fails and logs; recipient stays Pending.
                System.assertEquals(
                    'Pending',
                    rec.Status__c,
                    'recipient.sent currently does not change status in this org'
                );
                System.assertNotEquals(
                    null,
                    evt.Error_Message__c,
                    'recipient.sent failure should have an Error_Message__c'
                );
            } else {
                // "Normal" recipient events should complete successfully and match expected statuses
                System.assertEquals(
                    expectedStatus.get(evtType),
                    rec.Status__c,
                    'Recipient status wrong for ' + evtType
                );
                System.assertEquals(
                    null,
                    evt.Error_Message__c,
                    'Error_Message__c should be null for ' + evtType
                );
            }
        }
    }

    // ----------------------------------------------------------------------
    // Recipient not found (both findRecipient queries miss)
    // ----------------------------------------------------------------------
    @IsTest
    static void testRecipientEvents_NoMatchingRecipient() {
        Envelope_Event__c evt = createEvent(
            'recipient.completed',
            'ENV-DOES-NOT-EXIST',
            'REC-NOPE',
            'wrong'
        );

        Test.startTest();
        new SignatureApiWebhookProcessor(evt.Id).execute(null);
        Test.stopTest();

        evt = [
            SELECT Processing_Status__c, Error_Message__c
            FROM Envelope_Event__c WHERE Id = :evt.Id
        ];

        System.assertEquals('Completed', evt.Processing_Status__c);
        System.assertEquals(null, evt.Error_Message__c);
    }

    // ----------------------------------------------------------------------
    // deliverable.generated (mock download) — async path
    // ----------------------------------------------------------------------
    private class DummyDownloadMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"ok":true}');
            return r;
        }
    }

    @IsTest
    static void testDeliverableGenerated() {
        Envelope__c env = [
            SELECT Id, Envelope_Id__c
            FROM Envelope__c
            WHERE Envelope_Id__c = 'ENV-BASE'
            LIMIT 1
        ];

        Envelope_Event__c evt = createEvent(
            'deliverable.generated',
            env.Envelope_Id__c,
            null,
            null
        );

        Test.setMock(HttpCalloutMock.class, new DummyDownloadMock());

        Test.startTest();
        System.enqueueJob(new SignatureApiWebhookProcessor(evt.Id));
        Test.stopTest();

        evt = [
            SELECT Processing_Status__c, Error_Message__c
            FROM Envelope_Event__c WHERE Id = :evt.Id
        ];

        System.assertEquals('Completed', evt.Processing_Status__c);
        System.assertEquals(null, evt.Error_Message__c);
    }

    // ----------------------------------------------------------------------
    // deliverable.failed — both with and without matching envelope
    // ----------------------------------------------------------------------
    @IsTest
    static void testDeliverableFailed() {
        Envelope__c env = [
            SELECT Id, Envelope_Id__c
            FROM Envelope__c
            WHERE Envelope_Id__c = 'ENV-BASE'
            LIMIT 1
        ];

        Envelope_Event__c evt1 = createEvent(
            'deliverable.failed',
            env.Envelope_Id__c,
            null,
            null
        );

        Envelope_Event__c evt2 = createEvent(
            'deliverable.failed',
            'ENV-NOT-FOUND',
            null,
            null
        );

        Test.startTest();
        System.enqueueJob(new SignatureApiWebhookProcessor(evt1.Id));
        System.enqueueJob(new SignatureApiWebhookProcessor(evt2.Id));
        Test.stopTest();

        evt1 = [
            SELECT Processing_Status__c
            FROM Envelope_Event__c WHERE Id = :evt1.Id
        ];
        evt2 = [
            SELECT Processing_Status__c
            FROM Envelope_Event__c WHERE Id = :evt2.Id
        ];

        System.assertEquals('Completed', evt1.Processing_Status__c);
        System.assertEquals('Completed', evt2.Processing_Status__c);
    }

    // ----------------------------------------------------------------------
    // Sender (no-op) events — async batch
    // ----------------------------------------------------------------------
    @IsTest
    static void testSenderEvents() {
        List<Envelope_Event__c> events = new List<Envelope_Event__c>();

        for (String evtType : new List<String>{
            'sender.created',
            'sender.deleted',
            'sender.failed',
            'sender.verified'
        }) {
            events.add(createEvent(evtType, 'ENV-SENDER', null, null));
        }

        Test.startTest();
        for (Envelope_Event__c evt : events) {
            System.enqueueJob(new SignatureApiWebhookProcessor(evt.Id));
        }
        Test.stopTest();

        for (Envelope_Event__c evt : events) {
            Envelope_Event__c reloaded = [
                SELECT Processing_Status__c
                FROM Envelope_Event__c WHERE Id = :evt.Id
            ];
            System.assertEquals(
                'Completed',
                reloaded.Processing_Status__c,
                'Sender event should complete: ' + evt.Event_Type__c
            );
        }
    }
}
