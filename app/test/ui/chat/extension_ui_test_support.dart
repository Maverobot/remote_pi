import 'dart:async';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ExtensionUiTestChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];
  Object? sendError;
  Completer<void>? sendPending;
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage msg) async {
    await sendPending?.future;
    final error = sendError;
    if (error != null) throw error;
    sent.add(msg);
  }

  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
  void pushControl(ControlInbound frame) => _control.add(frame);
}

class ExtensionUiTestSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _s = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _s[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _s.remove(key);
    } else {
      _s[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const extensionUiTestPeer = PeerRecord(
  remoteEpk: 'epk_extui',
  sessionName: 'Pi',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

class ExtensionUiTestStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [extensionUiTestPeer];
  @override
  Future<PeerRecord?> loadPeer(String epk) async =>
      epk == extensionUiTestPeer.remoteEpk ? extensionUiTestPeer : null;
  @override
  Future<void> savePeer(PeerRecord r) async {}

  final Map<String, List<PersistedRoom>> _rooms = {};
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async =>
      _rooms[epk] = rooms;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];
  @override
  Future<void> deleteRooms(String epk) async => _rooms.remove(epk);
}

Future<
  ({
    ExtensionUiTestChannel ch,
    ConnectionManager conn,
    SyncService sync,
    ChatViewModel vm,
    Preferences prefs,
  })
>
extensionUiHarness() async {
  final ch = ExtensionUiTestChannel();
  final storage = ExtensionUiTestStorage();
  final conn = ConnectionManager(factory: (_, _) async => ch, storage: storage);
  final boxes = LocalBoxes();
  final sync = SyncService(conn, boxes);
  final read = SessionReadRepository(boxes);
  final prefs = Preferences(ExtensionUiTestSecureStorage());
  await prefs.setSelectedPeerEpk(extensionUiTestPeer.remoteEpk);
  await prefs.setSelectedRoom(
    epk: extensionUiTestPeer.remoteEpk,
    roomId: 'main',
  );

  conn.adopt(ch, extensionUiTestPeer);
  await Future<void>.delayed(const Duration(milliseconds: 30));
  final vm = ChatViewModel(read, sync, conn, prefs, storage);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return (ch: ch, conn: conn, sync: sync, vm: vm, prefs: prefs);
}
