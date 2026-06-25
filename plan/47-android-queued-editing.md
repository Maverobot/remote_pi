# 47 — Android-owned queued follow-up MVP

> **For agentic workers:** REQUIRED SUB-SKILL: use `subagent-driven-development` or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not edit app/pi-extension code from the monorepo root; dispatch or work inside the owning subproject.

**Goal:** Android shows queued follow-up messages, lets the user edit/clear Android-owned queued follow-ups before delivery, and drains them safely after the current Pi turn.

**Architecture:** Keep the app SSOT rule: `SyncService` is the only transport/DB writer, and UI reads queue/session state through `ChatViewModel`. Remote Pi owns a small explicit follow-up queue for Android; it is separate from Pi SDK internal steering/follow-up queues because the extension API does not expose stable queue item IDs or mutation APIs. Draining a queued Android item follows the same invariants as a normal accepted app user message: seed `_currentTurnId`, hand off to Pi, echo `user_message` to all owners, then let existing chunk/done forwarding finish the turn.

**Tech Stack:** TypeScript `pi-extension`, Pi extension API, Flutter/Dart app, Hive row-granular SSOT, existing `vitest` + `flutter test`.

## Global Constraints

- No code changes outside `app/` and `pi-extension/` for implementation; this root `plan/` file is planning only.
- No new dependencies.
- Preserve current Plan 43 behavior: while working, the main send action still sends **steer now**.
- Queue is additive: while working with text, Android shows a separate Queue button for “run after current turn”.
- Queue MVP is text-only. Image attachments keep the existing send/steer path.
- Android-owned queued items are editable/clearable by Android before delivery.
- Pi/TUI-originated SDK queued messages are **out of MVP**. No text matching, no internal SDK queue hacks.
- If Android sends a queued item while Pi is idle, Pi drains it immediately as a normal text user message and broadcasts an empty queue state.
- Multi-owner consistency is mandatory: every queue state change and every drained user message is broadcast to all active owners.
- Sent-message editing is deferred to a separate feasibility plan. Do not implement `message_edit`, `entry_id`, or `ActionName.message_edit` in this plan.
- Run verification from `app/` or `pi-extension/`, not from the monorepo root.

---

## Review Corrections Applied

The first draft mixed a safe queue MVP with unsafe sent-message editing. Review found these implementation blockers, now removed or fixed here:

- Sent-message editing needs command-only `navigateTree` and stable history entry IDs; current router contexts cannot prove that safely. It is deferred.
- `message_edit` would require closed `ActionName` changes in TS and Dart; no `message_edit` appears in this plan.
- Replacing `_messageBuffer` history mapping risks regressing ask_user/tool/compaction/image replay; this plan does not touch history mapping.
- Queue drain must echo accepted queued messages as normal `user_message`; Task 3 requires this.
- Queue drain must handle `agent_end`/`turn_end` ordering; Task 3 uses one busy helper and tests both event orders.
- `_wakeAgent` only catches synchronous handoff rejection. Tests and wording only promise restore on synchronous rejection, not provider/runtime failures after handoff.
- Queue `mode` is not client-settable in this MVP. Android queue items are always follow-up.

---

## Current Evidence / Gaps

Already present:

- `PROTOCOL.md` documents a one-slot queue shape:
  - app → Pi: `queued_message_set`, `queued_message_clear`
  - Pi → app: `queued_message_state`
  - `session_sync` should send queued state before history.
- App protocol/data/UI has partial one-slot scaffolding:
  - `app/lib/protocol/protocol.dart`: `QueuedMessageSet`, `QueuedMessageClear`, `QueuedMessageState`
  - `app/lib/data/sync/sync_service.dart`: `setQueuedMessage`, `clearQueuedMessage`, `_queuedText`, `queuedStream`
  - `app/lib/ui/chat/viewmodels/chat_viewmodel.dart`: subscribes to queued state
  - `app/lib/ui/chat/chat_page.dart`: passes `queuedText`, `onSetQueued`, `onClearQueued`
  - `app/lib/ui/chat/widgets/input_bar.dart`: renders one queued preview and can pull it back into the composer
- Pi extension protocol types already include `queued_message_set` / `queued_message_clear`, but `pi-extension/src/index.ts` does not route them or send `queued_message_state` in `session_sync`.
- `InputBar.onSetQueued` is not used, so Android has no visible Queue button.
- Current compaction fix has a separate `_compactionQueue` for app `user_message` during compaction. Do not replace it; the editable follow-up queue is separate.

---

## Non-goals

- Sent-message editing from Android.
- In-place mutation of already-sent user history.
- Editing Pi/TUI internal SDK queues.
- Queueing images.
- Replacing steer-now as the default main send action while working.
- Persisting queued items to disk across Pi process restarts.
- New relay behavior.

---

## UX

1. Idle composer:
   - Send submits a normal user message.
   - Queue button is hidden.
2. Working composer with text and no image:
   - Main send button still sends steer-now.
   - A compact Queue/clock icon appears beside Send/Stop.
   - Stop remains reachable through the existing inline stop affordance.
3. Queued rows above composer:
   - Show `Queued follow-up · <preview>`.
   - Editable Android-owned rows have tap-to-edit and clear (`x`).
4. Tap-to-edit behavior:
   - Tapping a queued row clears that queued item on Pi and places the text back into the composer.
   - If the user abandons the edit, the queued item is gone. This is deliberate for the MVP; it avoids distributed draft locks across multiple Android owners.
5. Multi-owner behavior:
   - Queue/clear/edit updates every connected Android owner.
   - Drained item appears as a normal user bubble on every connected owner.

---

## Wire Contract

### Client → Pi

Existing messages are extended minimally:

```json
{ "type": "queued_message_set", "id": "q_123", "text": "run tests after this" }
{ "type": "queued_message_clear", "id": "req_1", "target_id": "q_123" }
{ "type": "queued_message_clear", "id": "req_2" }
```

Rules:

- `queued_message_set.id` is the queue item id.
- Reusing the same item id replaces that item text.
- `queued_message_set.text.trim() === ""` clears that item id.
- `queued_message_clear.target_id` clears one item.
- `queued_message_clear` without `target_id` clears all Android-owned queued items, preserving the old one-slot clear intent.

### Pi → app(s)

`queued_message_state` keeps legacy `id`/`text` and adds plural `items`:

```json
{
  "type": "queued_message_state",
  "id": "q_123",
  "text": "run tests after this",
  "items": [
    {
      "id": "q_123",
      "text": "run tests after this",
      "editable": true,
      "created_at": 1782250000000
    }
  ]
}
```

Empty state:

```json
{ "type": "queued_message_state", "items": [] }
```

Compatibility:

- Older apps read `id`/`text` and show only the first queued item.
- Newer apps reading an older Pi build fall back from missing `items` to legacy `id`/`text`.

---

## File Map

### Docs / protocol

- Modify: `PROTOCOL.md`
  - Document plural `queued_message_state.items`, optional `target_id`, idle immediate drain, and Android-owned edit semantics.

### Pi extension

- Modify: `pi-extension/src/protocol/types.ts`
  - Add `QueuedMessageItem`.
  - Add `target_id?: string` to `queued_message_clear`.
  - Add `items?: QueuedMessageItem[]` to `queued_message_state`.
- Modify: `pi-extension/src/protocol/codec.ts` only if codec fixtures enumerate server/client message types.
- Modify: `pi-extension/src/index.ts`
  - Add module-local Android queued item store.
  - Handle `queued_message_set` and `queued_message_clear`.
  - Broadcast queue state on set/clear/drain/session reset/relay close.
  - Send queue state before `session_history` in `session_sync`.
  - Drain one queued item when safe, preserving normal app-user turn invariants.
- Test: `pi-extension/src/extension.test.ts`
  - Queue set/replace/clear/sync/drain/multi-owner/order tests.

### App protocol/data/domain/UI

- Modify: `app/lib/protocol/protocol.dart`
  - Add `QueuedMessageItem` parser.
  - Add `QueuedMessageState.items` with legacy fallback.
  - Add `QueuedMessageClear.targetId` encoder.
- Modify: `app/lib/domain/session_state.dart`
  - Add protocol-free domain value `QueuedMsg`.
- Modify: `app/lib/data/sync/sync_service.dart`
  - Replace one `String?` queue state with `List<QueuedMsg>` state/stream.
  - Keep `queuedText` compatibility getter only if it reduces diff.
  - Add queue and clear-by-id commands.
- Modify: `app/lib/ui/chat/states/chat_state.dart`
  - Add `queuedMessages`.
- Modify: `app/lib/ui/chat/viewmodels/chat_viewmodel.dart`
  - Expose queue list and commands.
- Modify: `app/lib/ui/chat/chat_page.dart`
  - Pass queue list and callbacks to `InputBar`.
- Modify: `app/lib/ui/chat/widgets/input_bar.dart`
  - Add Queue icon and plural queue preview/edit rows.
- Tests:
  - `app/test/ui/chat/input_bar_test.dart`
  - `app/test/ui/chat/chat_viewmodel_test.dart`
  - protocol test file used by existing protocol tests.

---

## Task 1 — Protocol docs and queue schema

**Files:**

- Modify: `PROTOCOL.md`
- Modify: `pi-extension/src/protocol/types.ts`
- Modify: `app/lib/protocol/protocol.dart`
- Test: existing app protocol tests and TS type/codec tests.

**Interfaces produced:**

TS:

```ts
export type QueuedMessageItem = {
  id: string;
  text: string;
  editable: boolean;
  created_at: number;
};
```

Dart:

```dart
class QueuedMessageItem {
  final String id;
  final String text;
  final bool editable;
  final DateTime createdAt;
}
```

- [x] **Step 1: Write failing Dart protocol tests**

Add or extend the existing protocol test with:

```dart
test('queued_message_state parses plural items and legacy fallback', () {
  final plural = ServerMessage.fromJson({
    'type': 'queued_message_state',
    'items': [
      {
        'id': 'q1',
        'text': 'next',
        'editable': true,
        'created_at': 123,
      },
    ],
  }) as QueuedMessageState;

  expect(plural.items, hasLength(1));
  expect(plural.items.single.id, 'q1');
  expect(plural.items.single.text, 'next');
  expect(plural.items.single.editable, isTrue);
  expect(plural.text, 'next');

  final legacy = ServerMessage.fromJson({
    'type': 'queued_message_state',
    'id': 'old',
    'text': 'legacy',
  }) as QueuedMessageState;

  expect(legacy.items, hasLength(1));
  expect(legacy.items.single.id, 'old');
  expect(legacy.items.single.text, 'legacy');
  expect(legacy.items.single.editable, isTrue);
});

test('queued_message_clear can target one queued item', () {
  expect(
    QueuedMessageClear(id: 'req1', targetId: 'q1').toJson(),
    {'type': 'queued_message_clear', 'id': 'req1', 'target_id': 'q1'},
  );
  expect(
    QueuedMessageClear(id: 'req2').toJson(),
    {'type': 'queued_message_clear', 'id': 'req2'},
  );
});
```

Run from `app/`:

```bash
flutter test test/protocol_test.dart --plain-name queued_message_state
```

Expected before implementation: fails because `items`/`targetId` do not exist.

- [x] **Step 2: Implement Dart protocol parsing/encoding**

Implementation rules:

- `QueuedMessageState.items` parses `items` when present.
- If `items` is absent and `text` is non-empty, create one legacy item from `id/text`.
- If both are absent/empty, `items == const []` and `text == null`.
- `created_at` is milliseconds since epoch; missing value maps to `DateTime.fromMillisecondsSinceEpoch(0)`.
- `QueuedMessageState.id` / `text` return the first item for compatibility.

- [x] **Step 3: Add TS types**

Update `pi-extension/src/protocol/types.ts` so these compile:

```ts
const clearOne: ClientMessage = { type: "queued_message_clear", id: "req1", target_id: "q1" };
const clearAll: ClientMessage = { type: "queued_message_clear", id: "req2" };
const state: ServerMessage = {
  type: "queued_message_state",
  id: "q1",
  text: "next",
  items: [{ id: "q1", text: "next", editable: true, created_at: 123 }],
};
```

Do not add `message_edit` or queue `mode` types.

- [x] **Step 4: Update `PROTOCOL.md`**

Replace the old one-slot queue section with the wire contract above. Explicitly state:

- Android queue is text-only follow-up.
- Idle set drains immediately.
- Pi/TUI internal queues are not exposed in this MVP.

- [x] **Step 5: Verify Task 1**

Run:

```bash
cd pi-extension && ../node_modules/.bin/tsc --noEmit
cd app && flutter test test/protocol_test.dart
```

Expected: typecheck and protocol tests pass.

---

## Task 2 — Pi-extension queue state and sync

**Files:**

- Modify: `pi-extension/src/index.ts`
- Test: `pi-extension/src/extension.test.ts`

**Interfaces consumed:** Task 1 TS `QueuedMessageItem`.

**Interfaces produced:**

```ts
type AndroidQueuedItem = {
  id: string;
  text: string;
  editable: true;
  created_at: number;
};
```

Helpers:

```ts
function _sendQueuedState(sender: PlainPeerChannel): void;
function _broadcastQueuedState(): void;
function _upsertQueuedItem(item: AndroidQueuedItem): void;
function _clearQueuedItems(targetId?: string): void;
```

- [x] **Step 1: Write failing queue state tests**

Add tests in `pi-extension/src/extension.test.ts`:

1. While working, `queued_message_set` broadcasts one queued item to every active owner.
2. Reusing the same item id replaces text and keeps one item.
3. `queued_message_clear { target_id }` removes only that item.
4. `queued_message_clear` without `target_id` clears all Android queue items.
5. `session_sync` sends `queued_message_state` before `session_history`.
6. `session_new` / relay close broadcasts empty queue state.

Use production routing (`_routeClientMessageFrom`) and captured event handlers already used by nearby tests. For “working”, trigger the captured `turn_start` or set the same room-meta path existing tests use; do not expect a queued item while idle.

Expected failing assertion before implementation:

```ts
expect(ownerA.sent).toContainEqual(expect.objectContaining({
  type: "queued_message_state",
  items: [expect.objectContaining({ id: "q1", text: "next", editable: true })],
}));
```

Run:

```bash
cd pi-extension && ../node_modules/.bin/vitest run src/extension.test.ts -t queued_message
```

Expected before implementation: fails because router ignores queued messages.

- [x] **Step 2: Add module-local queue store**

In `pi-extension/src/index.ts` near current turn/compaction module state:

```ts
let _queuedItems: AndroidQueuedItem[] = [];
```

Keep this independent from existing `_compactionQueue`.

- [x] **Step 3: Implement state send/broadcast helpers**

`_sendQueuedState(sender)` sends:

```ts
const first = _queuedItems[0];
sender.send({
  type: "queued_message_state",
  ...(first ? { id: first.id, text: first.text } : {}),
  items: _queuedItems.map((item) => ({ ...item })),
});
```

`_broadcastQueuedState()` calls `_sendQueuedState` for all active owners.

- [x] **Step 4: Route set/clear messages**

Add cases in `_routeClientMessageFrom`:

```ts
case "queued_message_set": {
  const text = msg.text.trim();
  if (!text) {
    _clearQueuedItems(msg.id);
    break;
  }
  _upsertQueuedItem({ id: msg.id, text, editable: true, created_at: Date.now() });
  _maybeDrainQueuedItem();
  break;
}
case "queued_message_clear":
  _clearQueuedItems(msg.target_id);
  break;
```

`_upsertQueuedItem` broadcasts state after mutation unless `_maybeDrainQueuedItem` drains immediately. Simpler acceptable implementation: broadcast queued state after upsert, then if idle drain and broadcast empty state. Tests should accept the final empty state in idle case.

- [x] **Step 5: Send queue state during sync**

At the start of `_handleSessionSync`, before `session_history`, call:

```ts
_sendQueuedState(sender);
```

- [x] **Step 6: Reset queue on session/relay teardown**

Clear queue and broadcast empty state on:

- successful `_resetSessionForNew`
- relay close / `_goIdle` teardown paths that clear active peers
- extension-level shutdown path if one exists beside relay close

Do not clear queue on ordinary `turn_end`; that is handled by drain.

- [x] **Step 7: Verify Task 2**

Run:

```bash
cd pi-extension && ../node_modules/.bin/vitest run src/extension.test.ts -t queued_message
cd pi-extension && ../node_modules/.bin/tsc --noEmit
```

Expected: queue state/sync tests pass.

---

## Task 3 — Pi-extension drain lifecycle and echo invariants

**Files:**

- Modify: `pi-extension/src/index.ts`
- Test: `pi-extension/src/extension.test.ts`

**Interfaces consumed:** Task 2 `_queuedItems`, `_broadcastQueuedState`.

**Interfaces produced:** Accepted queued items become normal app user turns after the active turn finishes.

- [x] **Step 1: Write failing drain tests**

Add tests for:

1. While working, `queued_message_set` does not call `_pi.sendUserMessage` immediately.
2. While idle, `queued_message_set` drains immediately and final queue state is empty.
3. Draining seeds `_currentTurnId` with the queued item id.
4. Draining calls `_wakeAgent(item.text, ..., "steer")` as an SDK-safe handoff; the app echo still omits `streaming_behavior` so it renders as a normal queued follow-up.
5. After synchronous handoff succeeds, draining broadcasts `user_message { id, text }` with no `streaming_behavior` to all owners.
6. A later `message_update` chunk uses `in_reply_to` equal to the queued item id.
7. `agent_end` before `turn_end` drains exactly once after both “not current turn” and “not working” are true.
8. `turn_end` before `agent_end` drains exactly once after both “not current turn” and “not working” are true.
9. A synchronous `_wakeAgent` rejection restores the item and broadcasts it again.
10. Async provider/runtime failure after accepted handoff is not restored; existing `error`/`agent_done` behavior handles the visible turn.

Run:

```bash
cd pi-extension && ../node_modules/.bin/vitest run src/extension.test.ts -t "queued drain"
```

Expected before implementation: fails because no drain exists.

- [x] **Step 2: Add one busy helper**

```ts
function _isBusyForQueueDrain(): boolean {
  return _compactionActive || _currentTurnId !== null || _myRoomMeta?.working === true;
}
```

This helper is the only drain gate. Tests must cover both `agent_end`/`turn_end` orderings.

- [x] **Step 3: Implement `_maybeDrainQueuedItem`**

Pseudo-code:

```ts
function _maybeDrainQueuedItem(): void {
  if (_isBusyForQueueDrain()) return;
  const item = _queuedItems.shift();
  if (!item) return;

  _broadcastQueuedState();
  const previousTurnId = _currentTurnId;
  _currentTurnId = item.id;

  const msg: ClientUserMessage = { type: "user_message", id: item.id, text: item.text };
  const wake = _wakeAgent(item.text, `queued app user_message id=${item.id}`, "steer");
  if (!wake.ok) {
    _currentTurnId = previousTurnId;
    _queuedItems.unshift(item);
    _broadcastQueuedState();
    _broadcastToActive({
      type: "error",
      code: "internal_error",
      in_reply_to: item.id,
      message: `Agent rejected queued message: ${wake.detail}`,
    });
    return;
  }

  _echoUserMessage(msg, false);
}
```

Key invariant: echo happens only after synchronous SDK handoff is accepted.

- [x] **Step 4: Call drain from both lifecycle events**

At the end of `agent_end`, after broadcasting `agent_done` and setting `_currentTurnId = null`, call:

```ts
_maybeDrainQueuedItem();
```

At the end of `turn_end`, after publishing `working=false`, call:

```ts
_maybeDrainQueuedItem();
```

Both calls are required because event ordering can vary.

- [x] **Step 5: Integrate compaction safely**

In `_endCompaction`:

- Keep existing `_compactionQueue` behavior unchanged.
- If `_compactionQueue` has items, drain that existing steer queue first and let the next `agent_end`/`turn_end` drain Android follow-ups.
- If `_compactionQueue` is empty, schedule `_maybeDrainQueuedItem()` after `_publishWorking(false)`.

This preserves order: direct app messages sent during compaction (existing steer behavior) are not overtaken by follow-up queue items.

- [x] **Step 6: Verify Task 3**

Run:

```bash
cd pi-extension && ../node_modules/.bin/vitest run src/extension.test.ts -t "queued"
cd pi-extension && ../node_modules/.bin/tsc --noEmit
```

Expected: all queue/drain tests pass.

---

## Task 4 — App queue state in SyncService and ChatViewModel

**Files:**

- Modify: `app/lib/domain/session_state.dart`
- Modify: `app/lib/data/sync/sync_service.dart`
- Modify: `app/lib/ui/chat/states/chat_state.dart`
- Modify: `app/lib/ui/chat/viewmodels/chat_viewmodel.dart`
- Test: `app/test/ui/chat/chat_viewmodel_test.dart`
- Test: existing SyncService tests if present.

**Interfaces consumed:** Task 1 Dart protocol.

**Interfaces produced:**

```dart
class QueuedMsg {
  final String id;
  final String text;
  final bool editable;
  final DateTime createdAt;
}
```

`QueuedMsg` is a domain/UI value. It must not import protocol types.

ViewModel commands:

```dart
void queueMessage(String text);
void clearQueuedMessage(String id);
void clearQueuedMessages();
```

- [x] **Step 1: Write failing ViewModel/SyncService tests**

Add tests that assert:

1. `QueuedMessageState(items:[...])` updates `ChatReady.queuedMessages`.
2. Legacy `QueuedMessageState(id/text)` updates `ChatReady.queuedMessages` with one item.
3. Empty `QueuedMessageState(items:[])` clears the queue.
4. `queueMessage('x')` sends `QueuedMessageSet` with generated id and text `x`.
5. `clearQueuedMessage('q1')` sends `QueuedMessageClear(targetId:'q1')`.
6. Queue clears on session switch through existing `_resetTurnState` path.
7. Receiving drained `user_message` echo removes the matching queued item if still present locally.

- [x] **Step 2: Add domain `QueuedMsg`**

In `app/lib/domain/session_state.dart`:

```dart
class QueuedMsg {
  final String id;
  final String text;
  final bool editable;
  final DateTime createdAt;

  const QueuedMsg({
    required this.id,
    required this.text,
    required this.editable,
    required this.createdAt,
  });

  @override
  bool operator ==(Object other) =>
      other is QueuedMsg &&
      other.id == id &&
      other.text == text &&
      other.editable == editable &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, text, editable, createdAt);
}
```

- [x] **Step 3: Replace SyncService one-slot queue state**

Use list state:

```dart
List<QueuedMsg> _queuedMessages = const [];
final StreamController<List<QueuedMsg>> _queuedController =
    StreamController<List<QueuedMsg>>.broadcast();

List<QueuedMsg> get queuedMessages => _queuedMessages;
String? get queuedText => _queuedMessages.isEmpty ? null : _queuedMessages.first.text;
Stream<List<QueuedMsg>> get queuedStream => _queuedController.stream;
```

Keep `queuedText` only as a compatibility getter for existing code during the migration.

- [x] **Step 4: Map protocol queue state to domain queue state**

In `case QueuedMessageState`, map each protocol item to `QueuedMsg`. Emit an immutable list copy.

If legacy fallback produces one item with `createdAt` epoch zero, that is acceptable; UI does not display time.

- [x] **Step 5: Add queue commands**

`queueMessage`:

```dart
Future<void> queueMessage(String text) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  final id = _newId();
  _setQueuedMessages([
    ..._queuedMessages,
    QueuedMsg(id: id, text: trimmed, editable: true, createdAt: DateTime.now()),
  ]);
  final ch = _conn.channel;
  if (ch == null) return;
  await ch.send(QueuedMessageSet(id: id, text: trimmed));
}
```

`clearQueuedMessage(id)` removes that id optimistically and sends targeted clear if online.

`clearQueuedMessages()` clears all optimistically and sends untargeted clear if online.

- [x] **Step 6: Update ChatState/ViewModel**

Add `queuedMessages` to `ChatReady`, equality, `copyWith`, and `_compose`.

In `ChatViewModel`, listen to the new list stream and expose:

```dart
List<QueuedMsg> get queuedMessages => _queuedMessages;
void queueMessage(String text) => unawaited(_sync.queueMessage(text));
void clearQueuedMessage(String id) => unawaited(_sync.clearQueuedMessage(id));
void clearQueuedMessages() => unawaited(_sync.clearQueuedMessages());
```

- [x] **Step 7: Verify Task 4**

Run:

```bash
cd app && flutter test test/ui/chat/chat_viewmodel_test.dart --plain-name queued
cd app && flutter analyze
```

Expected: focused tests pass. The known unrelated `axisAlignment` deprecation may remain only if it already appears in the baseline; do not fix it in this plan.

---

## Task 5 — App queued-message UI

**Files:**

- Modify: `app/lib/ui/chat/chat_page.dart`
- Modify: `app/lib/ui/chat/widgets/input_bar.dart`
- Test: `app/test/ui/chat/input_bar_test.dart`

**Interfaces consumed:** Task 4 `QueuedMsg` list and queue/clear callbacks.

**Interfaces produced:** visible editable queued rows and Queue button.

- [x] **Step 1: Write failing InputBar tests**

Add widget tests for:

1. While `streaming: true`, text entered, no image: Queue icon appears.
2. Tapping Queue calls `onSetQueued(text)`, clears composer, and does not call `onSend`.
3. Main Send while working still calls `onSend` so steer-now remains unchanged.
4. A queued row renders preview text.
5. Tapping editable queued row calls `onClearQueued(id)` and fills composer with queued text.
6. Clear button calls `onClearQueued(id)`.
7. Read-only queued row does not fill composer and has no clear button. This protects forward compatibility if Pi later emits read-only rows.
8. Queue icon is hidden when an image attachment is present.
9. Queue icon is hidden while idle.

- [x] **Step 2: Update InputBar props**

Replace one-slot props with list callbacks:

```dart
final List<QueuedMsg> queuedMessages;
final void Function(String text)? onSetQueued;
final void Function(String id)? onClearQueued;
```

Import `QueuedMsg` from `domain/session_state.dart`.

- [x] **Step 3: Add queue action**

When `widget.streaming && hasContent && !hasImage && canInteract`, show a compact Queue icon button.

Handler:

```dart
void _queueCurrentText() {
  final text = _controller.text.trim();
  if (text.isEmpty) return;
  _controller.clear();
  widget.onSetQueued?.call(text);
}
```

- [x] **Step 4: Render plural queued rows**

Render above the text field:

```dart
for (final item in widget.queuedMessages)
  _QueuedMessagePreview(
    text: item.text,
    editable: item.editable,
    onTap: item.editable ? () => _editQueued(item) : null,
    onClear: item.editable ? () => widget.onClearQueued?.call(item.id) : null,
  )
```

`_editQueued(item)`:

```dart
void _editQueued(QueuedMsg item) {
  if (!item.editable) return;
  widget.onClearQueued?.call(item.id);
  _controller.text = item.text;
  _controller.selection = TextSelection.collapsed(offset: item.text.length);
  _focusNode.requestFocus();
}
```

Do not keep a separate `_queued` string in `InputBar`; the widget should render `widget.queuedMessages` directly.

- [x] **Step 5: Wire ChatPage**

Pass:

```dart
queuedMessages: isReady ? state.queuedMessages : const [],
onSetQueued: vm.queueMessage,
onClearQueued: vm.clearQueuedMessage,
```

Keep existing `onSend` unchanged so steer-now still flows through `vm.sendMessage`.

- [x] **Step 6: Verify Task 5**

Run:

```bash
cd app && flutter test test/ui/chat/input_bar_test.dart --plain-name queued
cd app && flutter test test/ui/chat/chat_viewmodel_test.dart --plain-name queued
cd app && flutter analyze
```

Expected: focused UI/ViewModel tests pass and analyzer has no new issues.

---

## Task 6 — Full verification and manual smoke

**Files:** no code edits unless verification exposes a bug in changed code.

- [x] **Step 1: Full Pi-extension verification**

Run:

```bash
cd pi-extension && ../node_modules/.bin/tsc --noEmit
cd pi-extension && ../node_modules/.bin/vitest run
```

Expected: typecheck passes; all tests pass.

- [x] **Step 2: Full app verification**

Run:

```bash
cd app && flutter test --reporter=compact
cd app && flutter build apk --debug
```

Expected: tests pass; debug APK builds.

- [x] **Step 3: Manual queue smoke**

1. Start Pi with Remote Pi extension and open Android.
2. Start a long-running prompt from Android or Pi.
3. While Android shows working, type `run focused tests after this`.
4. Tap Queue.
5. Verify queued row appears on Android.
6. If a second Android owner is connected, verify the same queued row appears there.
7. Tap the queued row on one Android device, edit the text, tap Queue again.
8. Verify all Android owners show the updated queued row.
9. Let the current turn finish.
10. Verify the queued row disappears.
11. Verify the edited text appears as a normal user bubble on all owners.
12. Verify the agent responds to the edited text.

- [x] **Step 4: Manual idle protocol smoke**

Use a debug/test sender or temporary app path to send `queued_message_set` while Pi is idle.

Expected:

- Android does not get stuck showing a queued row.
- Pi broadcasts normal `user_message` for the queued text.
- Agent responds normally.

- [ ] **Step 5: Optional physical install if app changed**

If preparing a release APK for the user's device:

```bash
cd app && flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell monkey -p work.jacobmoura.remotepi 1
```

Expected: install says `Success`; app launches.

---

## Definition of Done

- [x] `PROTOCOL.md` documents plural Android-owned queued follow-ups and idle immediate drain.
- [x] Pi handles `queued_message_set` and `queued_message_clear`.
- [x] Pi sends `queued_message_state` before `session_history` in `session_sync`.
- [x] Pi broadcasts queue state changes to all active owners.
- [x] Pi drains queued Android follow-ups only when `_currentTurnId === null`, `_myRoomMeta.working !== true`, and `_compactionActive === false`.
- [x] Drained queued item is echoed as normal `user_message` to all owners after synchronous SDK handoff is accepted.
- [x] Current steer-now behavior while working is unchanged.
- [x] Android displays queued follow-up rows.
- [x] Android can edit a queued row by pulling it back into the composer.
- [x] Android can clear one queued row.
- [x] Multi-owner queue state stays consistent.
- [x] Pi/TUI internal SDK queue editing is not attempted.
- [x] Sent-message editing is not implemented in this plan.
- [x] `cd pi-extension && ../node_modules/.bin/tsc --noEmit` passes.
- [x] `cd pi-extension && ../node_modules/.bin/vitest run` passes.
- [x] `cd app && flutter test --reporter=compact` passes.
- [x] `cd app && flutter build apk --debug` passes.

---

## Deferred: sent-message edit feasibility plan

Sent-message editing remains desirable, but it needs a separate feasibility plan before code changes. That plan must answer these questions with tests or Pi SDK evidence:

1. How does Remote Pi obtain a fresh, command-capable context with `navigateTree` for an app-originated request after `newSession`, `fork`, `switchSession`, and reload?
2. How does the app identify editable user messages without replacing `_messageBuffer` history mapping or regressing ask_user/tool/compaction/image sync?
3. After rewinding a branch and submitting edited text, when is the replacement `session_history` broadcast so it is not stale?
4. What user-visible copy explains that edit creates/replaces a branch, not a cosmetic in-place mutation?
5. How are multi-owner conflicts handled if one owner edits history while another is typing or has queued follow-ups?

Until those are answered, sent-message edit should stay disabled in Android.
