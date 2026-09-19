import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';

/// Turn IDs repeat across roles and assistant segments. Include assistant text
/// so trimming a different segment cannot shift an anchor onto another reply.
/// Count identical occurrences before filtering hidden tools.
typedef ChatMessageRowId = ({
  Type type,
  String messageId,
  String? assistantText,
  int occurrence,
});

Iterable<({ChatMessageRowId id, ChatMessage message})> chatMessageRows(
  List<ChatMessage> messages,
) sync* {
  final occurrences = <(Type, String, String?), int>{};
  for (final message in messages) {
    final assistantText = message is AssistantMsg ? message.text : null;
    final key = (message.runtimeType, message.id, assistantText);
    final occurrence = occurrences[key] ?? 0;
    occurrences[key] = occurrence + 1;
    yield (
      id: (
        type: message.runtimeType,
        messageId: message.id,
        assistantText: assistantText,
        occurrence: occurrence,
      ),
      message: message,
    );
  }
}

enum ExtensionUiFlowStatus { pending, completed, replaced }

/// Screen-local history only; never written to the message store.
class ExtensionUiFlow {
  final ExtensionUiRequest request;
  final ChatMessageRowId? afterMessageRowId;
  final ExtensionUiFlowStatus status;

  /// Successfully sent locally, not an authoritative server-accepted answer.
  final ExtensionUiResponse? submittedResponse;

  const ExtensionUiFlow({
    required this.request,
    required this.afterMessageRowId,
    this.status = ExtensionUiFlowStatus.pending,
    this.submittedResponse,
  });

  // A correlated tool can still be in SyncService's asynchronous write queue.
  // Once resolved, keep the exact row even if history later truncates it away.
  bool get awaitingToolRow =>
      request.ask?.toolCallId != null && afterMessageRowId == null;

  ExtensionUiFlow anchoredAfter(ChatMessageRowId rowId) => ExtensionUiFlow(
    request: request,
    afterMessageRowId: rowId,
    status: status,
    submittedResponse: submittedResponse,
  );

  ExtensionUiFlow withSubmittedResponse(ExtensionUiResponse? response) =>
      ExtensionUiFlow(
        request: request,
        afterMessageRowId: afterMessageRowId,
        status: status,
        submittedResponse: response,
      );

  ExtensionUiFlow withStatus(ExtensionUiFlowStatus status) => ExtensionUiFlow(
    request: request,
    afterMessageRowId: afterMessageRowId,
    status: status,
    submittedResponse: submittedResponse,
  );
}

// Sealed state for ChatViewModel.
// Switch exhaustively in ChatPage.build().

sealed class ChatState {
  const ChatState();
}

// No peer paired yet — show QR scanner redirect.
class ChatNoPeer extends ChatState {
  const ChatNoPeer();
}

// Establishing connection after boot or reconnect.
class ChatConnecting extends ChatState {
  const ChatConnecting();
}

// Connected and ready.
class ChatReady extends ChatState {
  final List<ChatMessage> messages;
  final StreamingMessage? streaming;
  final bool isOffline; // true → input disabled, banner visible
  // True once the Mac signalled this device is no longer in peers.json
  // (relay returned an `unknown_peer` error). Stays true until the user
  // re-pairs or revokes; suppresses input and surfaces a re-pair banner.
  final bool pairingRevoked;
  // Set when the Pi sent a `bye` (graceful disconnect). Stops retry,
  // shows banner offering manual reconnect. `peerOfflineReason` is the
  // raw wire reason (peer_stop / session_replaced / shutdown / …).
  final String? peerOfflineReason;

  /// Live relay-reported presence of the active peer. When the peer is
  /// [PresenceOffline] the chat enters read-only mode (history visible,
  /// input disabled). Defaults to [PresenceUnknown] until the relay
  /// reports.
  final PresenceState peerPresence;

  /// Plan/32 — whether the room this chat is viewing has an in-flight
  /// agent turn (drives the working pill + input-lock + stop button).
  /// Part of the state identity so a relay `meta.working` flip (which is
  /// per-room, like Home) actually triggers a rebuild even when nothing
  /// else changed. See [ChatViewModel.isWorking].
  final bool isWorking;
  final List<QueuedMsg> queuedMessages;

  /// Active upstream pi-ask request; cleared only on completion or replacement.
  final ExtensionUiRequest? pendingUiRequest;
  final String? pendingUiError;

  /// Distinguishes repeated identical failures coalesced into one UI frame.
  final int pendingUiErrorRevision;
  final List<ExtensionUiFlow> uiFlows;

  String? get queuedText =>
      queuedMessages.isEmpty ? null : queuedMessages.first.text;

  const ChatReady({
    required this.messages,
    this.streaming,
    this.isOffline = false,
    this.pairingRevoked = false,
    this.peerOfflineReason,
    this.peerPresence = const PresenceUnknown(),
    this.isWorking = false,
    this.queuedMessages = const [],
    this.pendingUiRequest,
    this.pendingUiError,
    this.pendingUiErrorRevision = 0,
    this.uiFlows = const [],
  });

  ChatReady copyWith({
    List<ChatMessage>? messages,
    StreamingMessage? streaming,
    bool? isOffline,
    bool? pairingRevoked,
    String? peerOfflineReason,
    PresenceState? peerPresence,
    bool? isWorking,
    List<QueuedMsg>? queuedMessages,
    bool clearStreaming = false,
    bool clearPeerOffline = false,
    bool clearQueuedMessages = false,
    ExtensionUiRequest? pendingUiRequest,
    bool clearPendingUiRequest = false,
    List<ExtensionUiFlow>? uiFlows,
    String? pendingUiError,
    int? pendingUiErrorRevision,
    bool clearPendingUiError = false,
  }) => ChatReady(
    messages: messages ?? this.messages,
    uiFlows: uiFlows ?? this.uiFlows,
    pendingUiErrorRevision:
        pendingUiErrorRevision ?? this.pendingUiErrorRevision,
    streaming: clearStreaming ? null : (streaming ?? this.streaming),
    isOffline: isOffline ?? this.isOffline,
    pairingRevoked: pairingRevoked ?? this.pairingRevoked,
    peerOfflineReason: clearPeerOffline
        ? null
        : (peerOfflineReason ?? this.peerOfflineReason),
    peerPresence: peerPresence ?? this.peerPresence,
    isWorking: isWorking ?? this.isWorking,
    queuedMessages: clearQueuedMessages
        ? const []
        : (queuedMessages ?? this.queuedMessages),
    pendingUiRequest: clearPendingUiRequest
        ? null
        : (pendingUiRequest ?? this.pendingUiRequest),
    pendingUiError: clearPendingUiError
        ? null
        : (pendingUiError ?? this.pendingUiError),
  );

  @override
  bool operator ==(Object other) =>
      other is ChatReady &&
      other.messages == messages &&
      other.streaming == streaming &&
      other.isOffline == isOffline &&
      other.pairingRevoked == pairingRevoked &&
      other.peerOfflineReason == peerOfflineReason &&
      other.peerPresence.runtimeType == peerPresence.runtimeType &&
      other.isWorking == isWorking &&
      other.queuedMessages == queuedMessages &&
      other.uiFlows == uiFlows &&
      other.pendingUiRequest == pendingUiRequest &&
      other.pendingUiError == pendingUiError &&
      other.pendingUiErrorRevision == pendingUiErrorRevision;

  @override
  int get hashCode => Object.hash(
    messages,
    streaming,
    isOffline,
    pairingRevoked,
    peerOfflineReason,
    peerPresence.runtimeType,
    isWorking,
    queuedMessages,
    uiFlows,
    pendingUiRequest,
    pendingUiError,
    pendingUiErrorRevision,
  );
}

// Permanent offline — must re-pair.
class ChatFatalError extends ChatState {
  final String message;
  const ChatFatalError(this.message);

  @override
  bool operator ==(Object other) =>
      other is ChatFatalError && other.message == message;

  @override
  int get hashCode => message.hashCode;
}
