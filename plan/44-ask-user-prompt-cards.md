# 44 — ask_user prompt cards in the mobile app

## Context

Plan 42 made remote **Stop** cancel/unblock a running `ask_user`, but it
explicitly did not render or answer prompts on the phone. Plan 43 unlocked
steering while Pi is working. The remaining UX gap is the one users expect from
Remote Pi: when the agent asks a question, the mobile app should show an inline
prompt card and let the owner answer from the phone.

After checking `pi-telegram`, the best first implementation is **not** generic
RPC `extension_ui_request`. pi-telegram handles this by intercepting the
`ask_user` tool at `tool_call`, sending a prompt card to Telegram, blocking the
local tool with a reason that tells the model to wait, and then sending the
Telegram answer as a normal user prompt. Remote Pi should mirror that product
shape.

Important constraints from the current codebase:

- The Flutter app has no `ask_user` request/response protocol today. Unknown
  server frames become `unsupported_type` in `PlainPeerChannel`.
- The app UI is shared Flutter/Dart under `app/lib/`, so prompt cards implemented
  there are not Android-only; the same implementation should run on iOS. iOS
  still needs its own build/smoke pass.
- Pi's `tool_call` event can see the prompt before execution, but blocking a
  tool call is not a waiting primitive: it returns an immediate error result.
- Remote Pi therefore uses a v2 dual-surface design: mirror the prompt to
  Android while letting the local `pi-ask-user` tool keep running.
- Generic `extension_ui_request` cards remain valuable later for setup wizards
  and other extension UI, but they are not required for this user-requested
  `ask_user` prompt-card slice.

**2026-06-11 correction:** real smoke showed the original v1 blocking design
was wrong for Pi: `{ block: true }` immediately completes the tool call as an
error result, and `pi-ask-user` renders that missing-response result as
`Cancelled` while the Android card remains open. Current code does not honor the
legacy `ask_user_prompt_cards` capability. The replacement capability is
`ask_user_prompt_cards_v2`: Android receives a prompt card, the CLI prompt stays
open, and the first answer resolves the other surface through a `pi-ask-user`
external responder bridge.

## Goal

Implement dual-surface `ask_user` prompts for Remote Pi: when the LLM calls
`ask_user` while one or more phones are connected, the pi-extension mirrors a
rich prompt card to mobile apps while the normal local CLI `ask_user` UI remains
active. Whichever surface answers first resolves the other and returns a normal
`ask_user` tool result to the agent.

## Non-goals

- Do not reintroduce generic tool approval gates.
- Do not make push notifications part of this slice; prompts are answerable only
  while the app is open/connected.
- Do not implement generic `extension_ui_request` cards in this same slice.
- Do not silently shadow/replace the installed `pi-ask-user` tool.

## Wire contract

### Extension → app: `ask_user_prompt`

```json
{
  "type": "ask_user_prompt",
  "id": "tool_call_id",
  "question": "Which option should we use?",
  "context": "Relevant summary",
  "options": [
    { "title": "A", "description": "Fast path" },
    { "title": "B" }
  ],
  "allow_multiple": false,
  "allow_freeform": true,
  "allow_comment": false
}
```

`id` is the Pi tool call id. It is stable enough for first-response-wins and for
resolving the card across multiple phones.

### App → extension: `ask_user_response`

```json
{
  "type": "ask_user_response",
  "id": "tool_call_id",
  "response": {
    "kind": "selection",
    "selections": ["A"],
    "comment": "optional"
  }
}

{
  "type": "ask_user_response",
  "id": "tool_call_id",
  "response": { "kind": "freeform", "text": "Use B" }
}

{
  "type": "ask_user_response",
  "id": "tool_call_id",
  "cancelled": true
}
```

The extension accepts the first response for a pending id. In v2, an Android
response is delivered to the still-running local `pi-ask-user` tool via its
external responder bridge, so the LLM receives a normal `AskToolDetails` result
instead of a synthetic follow-up user message.

### Extension → app: `ask_user_resolved`

```json
{
  "type": "ask_user_resolved",
  "id": "tool_call_id",
  "answer_label": "A",
  "cancelled": false
}
```

Broadcast to all active owners after a prompt is answered/cancelled so other
phones do not keep stale actionable cards.

## App behavior

1. `ask_user_prompt` renders inline in the chat timeline as a rich card, near
   tool cards.
2. The card shows question, optional context, options with descriptions,
   `allowMultiple`, `allowFreeform`, and optional comment affordance.
3. Single-select prompts show option buttons and, when allowed, a freeform input.
4. Multi-select prompts allow selecting multiple options before Submit.
5. Freeform-only prompts show a text input.
6. Optional comments can be a compact additional text field rather than a hidden
   keyboard toggle.
7. Every card has Cancel.
8. Resolved cards become non-actionable summaries (`Answered: ...` or
   `Cancelled`).
9. Prompt rows are stored in the app SSOT so navigation/rebuild does not lose an
   open prompt while the app remains connected.

## Pi-extension behavior

1. Normalize `ask_user` tool input exactly like pi-telegram: `question`,
   `context`, string or `{title,description}` options, `allowMultiple`,
   `allowFreeform`, and `allowComment`.
2. In `tool_execution_start`, suppress the generic informational `tool_request`
   for `ask_user` when forwarding is possible, so the app does not show both a
   tool card and a prompt card.
3. In `tool_call`, when `event.toolName === "ask_user"` and at least one active
   owner advertises `ask_user_prompt_cards_v2`, register a pending prompt and
   broadcast `ask_user_prompt`; return `undefined` so local CLI execution
   continues.
4. Listen for `pi-ask-user`'s external responder event and attach its responder
   callback to the pending prompt. If Android already answered, resolve the CLI
   prompt immediately when the responder attaches.
5. Route `ask_user_response` in `_routeClientMessageFrom` before the `_pi` guard.
6. First response wins. Later responses are ignored or receive a correlated
   `error`.
7. When Android answers first, call the pending responder and broadcast
   `ask_user_resolved` to capable owners. Do not inject a steering user message.
8. When CLI answers first, consume `ask:answered` / `tool_result` and broadcast
   `ask_user_resolved` so Android cards become non-actionable.
9. If no active capable owner is connected, do nothing; the installed
   `pi-ask-user` tool keeps using local TUI/RPC UI as before.

## Steps

### Wave 0 — Protocol tests

Projects: `app/`, `pi-extension/`

Files:

- `app/lib/protocol/protocol.dart`
- `app/test/protocol_test.dart`
- `pi-extension/src/protocol/types.ts`
- `pi-extension/src/protocol/codec.ts`
- `pi-extension/src/protocol/codec.test.ts`

Tests first:

- Dart parses `ask_user_prompt`, including options with descriptions and all
  allow flags.
- Dart encodes `AskUserResponse` selection/freeform/cancel payloads.
- Dart parses `ask_user_resolved`.
- TS accepts server fixtures for `ask_user_prompt` / resolved and client fixtures
  for `ask_user_response`.
- Existing fixtures remain unchanged.

Acceptance:

- `cd app && flutter test test/protocol_test.dart`
- `cd pi-extension && corepack pnpm test -- src/protocol/codec.test.ts`
- `cd pi-extension && corepack pnpm typecheck`

### Wave 1 — App SSOT and ViewModel plumbing

Project: `app/`

Files:

- `lib/domain/session_state.dart`
- `lib/data/local/records/message_record.dart`
- `lib/data/sync/sync_service.dart`
- `lib/ui/chat/states/chat_state.dart` (only if needed)
- `lib/ui/chat/viewmodels/chat_viewmodel.dart`
- `test/data/sync/sync_service_test.dart`
- `test/ui/chat/chat_viewmodel_test.dart`

Tests first:

- Receiving an `AskUserPrompt` upserts a prompt chat row.
- Calling `ChatViewModel.respondAskUser(...)` sends the correct
  `AskUserResponse` through the channel.
- A local response optimistically marks the card resolved.
- Receiving `ask_user_resolved` marks the matching card resolved on every owner.
- Session switching clears only in-memory prompt response plumbing that belongs
  to the previous session and does not corrupt normal chat history.

Acceptance:

- `cd app && flutter test test/data/sync/sync_service_test.dart test/ui/chat/chat_viewmodel_test.dart`

### Wave 2 — App prompt card UI

Project: `app/`

Files:

- Create `lib/ui/chat/widgets/ask_user_prompt_card.dart`
- Modify `lib/ui/chat/chat_page.dart`
- Possibly modify `lib/ui/chat/widgets/message_bubble.dart`
- Add `test/ui/chat/ask_user_prompt_card_test.dart`

Tests first:

- Single-select renders options/descriptions and tapping one calls
  `onRespond(id, selection)`.
- Multi-select allows multiple selections and submit.
- Freeform submits `{kind:"freeform", text}`.
- Optional comment is included in selection responses.
- Cancel sends `{cancelled:true}`.
- Resolved prompt is non-actionable and shows the answer/cancel label.

Implementation notes:

- Reuse the visual language of `ToolRequestCard` and pi-telegram's prompt-card
  markdown semantics, but keep the widget in the app's theme system.
- Avoid `BuildContext` use after async callbacks; send through the VM and guard
  mounted context where needed.

Acceptance:

- `cd app && flutter test test/ui/chat/ask_user_prompt_card_test.dart`
- Repeat Wave 1 app tests.

### Wave 3 — Pi-extension ask_user forwarding bridge

Project: `pi-extension/`

Files:

- `src/index.ts`
- `src/extension.test.ts`
- possibly a small helper module `src/ask_user_forwarding.ts`

Tests first:

- `ask_user` tool calls with active v2 owners broadcast `ask_user_prompt` and do
  **not** return `{ block: true }`.
- Generic `tool_request` is not duplicated for mirrored `ask_user` prompts.
- A first Android `ask_user_response` broadcasts `ask_user_resolved`, calls the
  attached `pi-ask-user` responder, and does not inject a steering user message.
- If Android answers before the responder is attached, the response is stored and
  applied as soon as `pi-ask-user` emits its prompt bridge event.
- A CLI `ask:answered` / `tool_result` resolves the Android card.
- A second owner response for the same id is ignored or gets a correlated error;
  all owners keep the first resolution.
- Selection, freeform, comment, and cancellation are converted to normal
  `AskToolDetails` shape for the ask_user result.
- If no active v2 owner is connected, no mirroring happens and installed local
  `pi-ask-user` behavior remains unchanged.

Acceptance:

- `cd pi-extension && corepack pnpm test -- src/extension.test.ts`
- `cd pi-extension && corepack pnpm typecheck`

### Wave 4 — ask_user smoke matrix

Projects: `app/`, `pi-extension/`

Manual cases:

1. Android debug app connected to a normal interactive Pi TUI session.
2. Trigger a real `ask_user` tool call.
3. Verify the local ask_user overlay opens and the app shows the prompt card.
4. Answer from Android; verify the CLI prompt closes/marks answered, the Android
   card resolves, and the agent continues with the selected/freeform answer.
5. Repeat with a CLI answer first; verify the Android card resolves.
6. Repeat single select, freeform, multi-select, comment, and cancel cases.
7. Repeat on iOS simulator/device if available; if unavailable, at least run
   `flutter build ios --no-codesign`.

Acceptance:

- Android smoke passes for real interactive dual-surface `ask_user` prompts.
- iOS build or smoke passes.

Current smoke status:

- Android smoke is blocked on this host: `adb` is not installed, `flutter
  devices` only shows Linux desktop, and `flutter emulators` finds no Android
  emulator sources.
- iOS build/smoke is blocked on this host: this Flutter install exposes no
  `flutter build ios` subcommand on Linux.

## Definition of Done

- [x] App protocol parses `ask_user_prompt` / `ask_user_resolved` and encodes
      `ask_user_response`.
- [x] App advertises only v2 `ask_user_prompt_cards_v2`, not broken v1.
- [x] Pi-extension ignores v1 `ask_user_prompt_cards` and uses v2 dual-surface
      prompt mirroring without `{ block: true }`.
- [x] `pi-ask-user` exposes an external responder bridge so Android can answer
      the still-running local prompt.
- [x] App stores prompt cards in SSOT and survives navigation/rebuild.
- [x] App renders single-select, multi-select, freeform, optional comment,
      cancel, and resolved states.
- [x] First response wins across multiple active owners; stale cards resolve on
      all owners.
- [x] Prompt response does not disturb streaming, steering, or Stop/cancel state.
- [x] Relevant Flutter tests pass.
- [x] Relevant pi-extension tests and typecheck pass.
- [ ] Android manual smoke proves Android answer resolves CLI prompt and agent continues.
- [ ] iOS build/smoke verifies the shared Flutter implementation.
- [ ] Real interactive TUI `ask_user` smoke proves CLI answer resolves Android
      card and Android answer resolves CLI prompt.

## Risks

1. **Blocked-tool semantics (confirmed invalid for v1)**: Pi converts
   `{ block: true }` into an immediate error tool result, which `pi-ask-user`
   renders as `Cancelled`. V2 must never block the tool call; it resolves the
   running `pi-ask-user` prompt instead.
2. **Duplicate answers**: multiple phones may tap at once; extension must enforce
   first-response-wins.
3. **Prompt replay**: `session_sync` currently replays chat/tool/assistant events.
   Open prompt replay may need a small history extension if reconnect behavior is
   required beyond live connected owners.
4. **Rollout ordering**: extension must not emit prompt frames to older apps that
   would show `unsupported_type` unless version gating is added.
5. **Responder availability timing**: Android responses may arrive before
   `pi-ask-user` has attached its responder callback. The pending prompt stores
   the first response and resolves the CLI prompt as soon as the responder
   appears.

## Next plans

- Generic `extension_ui_request` cards for setup wizard / other extension UI,
  reusing Cockpit's RPC contract.
