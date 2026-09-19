// Upstream pi-ask request lifecycle and screen-local history.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'extension_ui_test_support.dart';

ExtensionUiRequest _request(String flowId) => ExtensionUiRequest(
  id: flowId,
  method: ExtensionUiMethod.select,
  title: 'Pick',
  options: const ['Alpha', 'Beta'],
  ask: AskEnrichmentWire(flowId: flowId, source: 'tool'),
);

late Directory _dir;

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_v2_extui_vm_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  test(
    'request opens card; warning notify sets error; completion retains read-only history',
    () async {
      final h = await extensionUiHarness();

      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f1');
      expect(state.pendingUiError, isNull);

      // submit-result rejection → same id, warning → card stays, error set.
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          message: 'Unknown option value.',
          notifyType: 'warning',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f1', reason: 'card stays open');
      expect(state.pendingUiError, 'Unknown option value.');

      // Retry clears the error before shipping the response.
      await h.vm.respondExtensionUi(
        ExtensionUiResponse(
          id: 'tool:f1',
          ask: const AskResponseEnrichmentWire(
            flowId: 'tool:f1',
            mode: 'submit',
          ),
        ),
      );
      state = h.vm.state as ChatReady;
      expect(state.pendingUiError, isNull);
      expect(
        h.ch.sent.whereType<ExtensionUiResponse>().single.id,
        'tool:f1',
        reason: 'response shipped over the live channel',
      );

      // completed → notify without warning type, same id → dismiss.
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          message: 'Clarification resolved.',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest, isNull, reason: 'request completed');
      expect(state.pendingUiError, isNull);
      expect(state.uiFlows.single.status, ExtensionUiFlowStatus.completed);

      h.vm.dispose();
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'unmatched notify is ignored; new request replaces the pending one',
    () async {
      final h = await extensionUiHarness();

      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Notify for some other id → no effect on the open card.
      h.ch.push(
        const ExtensionUiRequest(
          id: 'other',
          method: ExtensionUiMethod.notify,
          message: 'noise',
          notifyType: 'warning',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f1');
      expect(state.pendingUiError, isNull);

      // A new interactive request replaces the pending one (and clears errors).
      h.ch.push(_request('tool:f2'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f2');

      h.vm.dispose();
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'replays preserve one card and rejection; completed replay cannot reopen it',
    () async {
      final h = await extensionUiHarness();
      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          notifyType: 'warning',
          message: 'Retry answer',
        ),
      );
      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var state = h.vm.state as ChatReady;
      expect(state.uiFlows, hasLength(1));
      expect(state.pendingUiError, 'Retry answer');
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
        ),
      );
      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.uiFlows.single.status, ExtensionUiFlowStatus.completed);
      expect(state.pendingUiRequest, isNull);
      h.vm.dispose();
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'replacement is inert; stale replies and notifications do not affect the new flow',
    () async {
      final h = await extensionUiHarness();
      h.ch.push(_request('tool:f1'));
      h.ch.push(_request('tool:f2'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var state = h.vm.state as ChatReady;
      expect(state.uiFlows.map((flow) => flow.status), [
        ExtensionUiFlowStatus.replaced,
        ExtensionUiFlowStatus.pending,
      ]);
      h.ch.sent.clear();
      await h.vm.respondExtensionUi(
        ExtensionUiResponse(id: 'tool:f1', cancelled: true),
      );
      await h.vm.respondExtensionUi(
        ExtensionUiResponse(
          id: 'tool:f2',
          ask: const AskResponseEnrichmentWire(
            flowId: 'tool:f1',
            isCancel: true,
          ),
        ),
      );
      expect(h.ch.sent, isEmpty);
      h.ch.push(_request('tool:f1'));
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          notifyType: 'warning',
          message: 'Old rejection',
        ),
      );
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f2');
      expect(state.pendingUiError, isNull);
      expect(state.uiFlows.map((flow) => flow.status), [
        ExtensionUiFlowStatus.completed,
        ExtensionUiFlowStatus.pending,
      ]);
      h.vm.dispose();
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test('delayed send failure cannot attach to a replacement flow', () async {
    final h = await extensionUiHarness();
    h.ch.push(_request('tool:f1'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final send = Completer<void>();
    h.ch.sendPending = send;
    final response = h.vm.respondExtensionUi(
      ExtensionUiResponse(id: 'tool:f1', cancelled: true),
    );
    h.ch.push(_request('tool:f2'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    send.completeError(StateError('late disconnect'));
    await response;
    final state = h.vm.state as ChatReady;
    expect(state.pendingUiRequest?.id, 'tool:f2');
    expect(state.pendingUiError, isNull);
    h.vm.dispose();
    h.sync.dispose();
    h.conn.dispose();
  });

  for (final boundary in [
    'completion',
    'rejection',
    'reset',
    'replacement',
    'send failure',
    'rejection after completion',
  ]) {
    test('in-flight submission snapshot respects $boundary', () async {
      final h = await extensionUiHarness();
      try {
        await h.vm.clearActiveSession();
        h.ch.push(_request('snapshot'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final send = Completer<void>();
        h.ch.sendPending = send;
        final values = ['a'];
        final answers = {
          'goal': AskAnswerWire(values: values, customText: 'Sent text'),
        };
        final response = h.vm.respondExtensionUi(
          ExtensionUiResponse(
            id: 'snapshot',
            ask: AskResponseEnrichmentWire(
              flowId: 'snapshot',
              mode: 'submit',
              answers: answers,
            ),
          ),
        );
        h.ch.sendPending = null;
        values.add('b');
        answers.clear();
        expect(
          (h.vm.state as ChatReady).uiFlows.single.submittedResponse,
          isNull,
        );
        if (boundary == 'reset') {
          await h.vm.clearActiveSession();
        } else if (boundary == 'replacement') {
          h.ch.push(_request('replacement'));
        } else {
          if (boundary == 'rejection') {
            h.ch.push(
              const ExtensionUiRequest(
                id: 'snapshot',
                method: ExtensionUiMethod.notify,
                notifyType: 'warning',
                message: 'Rejected',
              ),
            );
          }
          h.ch.push(
            const ExtensionUiRequest(
              id: 'snapshot',
              method: ExtensionUiMethod.notify,
            ),
          );
        }
        if (boundary == 'rejection after completion') {
          h.ch.push(
            const ExtensionUiRequest(
              id: 'snapshot',
              method: ExtensionUiMethod.notify,
              notifyType: 'warning',
              message: 'Flow is no longer active',
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        if (boundary == 'send failure') {
          send.completeError(StateError('late disconnect'));
        } else {
          send.complete();
        }
        await response;
        final state = h.vm.state as ChatReady;
        if (boundary == 'completion') {
          expect(state.uiFlows.single.status, ExtensionUiFlowStatus.completed);
          final submitted =
              state.uiFlows.single.submittedResponse!.ask!.answers['goal']!;
          expect(submitted.values, ['a']);
          expect(submitted.customText, 'Sent text');
        } else {
          expect(
            state.uiFlows.every((flow) => flow.submittedResponse == null),
            isTrue,
          );
        }
        expect(state.pendingUiError, isNull);
      } finally {
        h.vm.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    });
  }

  for (final closedStatus in [
    ExtensionUiFlowStatus.completed,
    ExtensionUiFlowStatus.replaced,
  ]) {
    for (final notifyType in ['warning', 'error']) {
      test(
        '$notifyType invalidates $closedStatus without affecting a newer submission',
        () async {
          final h = await extensionUiHarness();
          Future<void> deliver(ServerMessage message) async {
            h.ch.push(message);
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }

          ExtensionUiResponse answer(String id) => ExtensionUiResponse(
            id: id,
            ask: AskResponseEnrichmentWire(
              flowId: id,
              mode: 'submit',
              answers: const {
                'goal': AskAnswerWire(values: ['a']),
              },
            ),
          );
          try {
            await h.vm.clearActiveSession();
            await deliver(_request('old'));
            await h.vm.respondExtensionUi(answer('old'));
            if (closedStatus == ExtensionUiFlowStatus.completed) {
              await deliver(
                const ExtensionUiRequest(
                  id: 'old',
                  method: ExtensionUiMethod.notify,
                ),
              );
            }
            await deliver(_request('new'));
            await h.vm.respondExtensionUi(answer('new'));
            final rejection = ExtensionUiRequest(
              id: 'old',
              method: ExtensionUiMethod.notify,
              notifyType: notifyType,
              message: 'Old answer rejected',
            );
            final before = h.vm.state as ChatReady;
            expect(before.uiFlows.first.status, closedStatus);
            expect(before.uiFlows.first.submittedResponse, isNotNull);
            final newerSubmission = before.uiFlows.last.submittedResponse;
            expect(newerSubmission, isNotNull);
            await deliver(rejection);
            final after = h.vm.state as ChatReady;
            expect(after.uiFlows.first.status, closedStatus);
            expect(after.uiFlows.first.submittedResponse, isNull);
            expect(after.uiFlows.last.submittedResponse, same(newerSubmission));
            expect(after.pendingUiRequest?.id, 'new');
            expect(after.pendingUiError, before.pendingUiError);
            expect(after.pendingUiErrorRevision, before.pendingUiErrorRevision);

            // A repeated old warning must not cancel the newer in-flight send.
            final send = Completer<void>();
            h.ch.sendPending = send;
            final response = h.vm.respondExtensionUi(answer('new'));
            h.ch.sendPending = null;
            await deliver(rejection);
            send.complete();
            await response;
            await deliver(
              const ExtensionUiRequest(
                id: 'new',
                method: ExtensionUiMethod.notify,
              ),
            );
            final completed = h.vm.state as ChatReady;
            expect(completed.uiFlows.first.submittedResponse, isNull);
            expect(
              completed.uiFlows.last.status,
              ExtensionUiFlowStatus.completed,
            );
            expect(
              completed
                  .uiFlows
                  .last
                  .submittedResponse!
                  .ask!
                  .answers['goal']!
                  .values,
              ['a'],
            );
            expect(completed.pendingUiError, isNull);
            expect(
              completed.pendingUiErrorRevision,
              before.pendingUiErrorRevision,
            );
          } finally {
            h.vm.dispose();
            h.sync.dispose();
            h.conn.dispose();
            h.prefs.dispose();
          }
        },
      );
    }
  }

  test(
    'respond with no live channel fails fast with a retryable error',
    () async {
      final ch = ExtensionUiTestChannel();
      final storage = ExtensionUiTestStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);

      // No adopt → no live channel → nothing sent, false returned.
      final sent = await sync.respondExtensionUi(
        ExtensionUiResponse(id: 'tool:f1', cancelled: true),
      );
      expect(sent, isFalse);
      expect(ch.sent, isEmpty);

      sync.dispose();
      conn.dispose();
    },
  );

  test('send exception becomes a retryable card error', () async {
    final h = await extensionUiHarness();

    h.ch.push(_request('tool:f1'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    h.ch.sent.clear(); // discard harness startup SessionSync
    h.ch.sendError = StateError('socket closed');

    await expectLater(
      h.vm.respondExtensionUi(
        ExtensionUiResponse(id: 'tool:f1', cancelled: true),
      ),
      completes,
    );

    final state = h.vm.state as ChatReady;
    expect(state.pendingUiRequest?.id, 'tool:f1', reason: 'card stays open');
    expect(
      state.pendingUiError,
      'Not connected — check the link to Pi and retry.',
    );
    expect(h.ch.sent, isEmpty);

    h.vm.dispose();
    h.sync.dispose();
    h.conn.dispose();
  });
}
