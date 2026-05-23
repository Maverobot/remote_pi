// Tests for the PairingStorage surface that survives plan 23 (W2A):
// PeerRecord (de)serialization, nickname/roomId edges, and the new
// `wipeAll()` helper that the OwnerIdentityBridge calls on sync-reset.

import 'package:app/pairing/storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

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
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(_store);

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.clear();

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.containsKey(key);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('PeerRecord — minimal post-rollback shape', () {
    test('serializes and deserializes the 4 retained fields', () {
      const record = PeerRecord(
        remoteEpk: 'pk_ed25519',
        sessionName: 'test',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      );

      final json = record.toJson();
      expect(json['remote_epk'], 'pk_ed25519');
      expect(json['session_name'], 'test');
      expect(json['relay_url'], 'ws://localhost');
      expect(json['paired_at'], '2026-01-01T00:00:00Z');
      expect(json['nickname'], isNull);

      final restored = PeerRecord.fromJson(json);
      expect(restored.remoteEpk, 'pk_ed25519');
      expect(restored.sessionName, 'test');
      expect(restored.nickname, isNull);
    });

    test('nickname round-trips through toJson/fromJson', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        sessionName: 'remote_pi · main',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        nickname: 'Mac de casa',
      );
      final restored = PeerRecord.fromJson(record.toJson());
      expect(restored.nickname, 'Mac de casa');
      expect(restored.sessionName, 'remote_pi · main');
    });

    test('legacy record without nickname field → fromJson returns null', () {
      final restored = PeerRecord.fromJson({
        'remote_epk': 'pk1',
        'session_name': 'name',
        'relay_url': 'ws://x',
        'paired_at': '2026-01-01T00:00:00Z',
      });
      expect(restored.nickname, isNull);
    });

    test('copyWith(nickname: null) clears the nickname', () {
      const record = PeerRecord(
        remoteEpk: 'pk1',
        sessionName: 'n',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
        nickname: 'old',
      );
      final cleared = record.copyWith(nickname: null);
      expect(cleared.nickname, isNull);

      final preserved = record.copyWith(sessionName: 'new');
      expect(preserved.nickname, 'old');
      expect(preserved.sessionName, 'new');
    });

    test('list/save/load round-trips through fake storage', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      const r = PeerRecord(
        remoteEpk: 'epk1',
        sessionName: 'sess',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      await storage.savePeer(r);

      final loaded = await storage.loadPeer('epk1');
      expect(loaded?.sessionName, 'sess');

      final all = await storage.listPeers();
      expect(all, hasLength(1));

      await storage.deletePeer('epk1');
      expect(await storage.listPeers(), isEmpty);
    });
  });

  group('PairingStorage.wipeAll (plan 23 sync-reset)', () {
    test('clears every peer + every persisted rooms entry', () async {
      final fake = _FakeSecureStorage();
      final storage = PairingStorage(fake);
      const a = PeerRecord(
        remoteEpk: 'epk-a',
        sessionName: 'A',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      const b = PeerRecord(
        remoteEpk: 'epk-b',
        sessionName: 'B',
        relayUrl: 'ws://x',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      await storage.savePeer(a);
      await storage.savePeer(b);
      await storage.saveRooms('epk-a', const [
        PersistedRoom(roomId: 'main', startedAt: 1700000000000),
      ]);

      expect(await storage.listPeers(), hasLength(2));
      expect(await storage.loadRooms('epk-a'), hasLength(1));

      await storage.wipeAll();

      expect(await storage.listPeers(), isEmpty);
      expect(await storage.loadRooms('epk-a'), isEmpty);
    });

    test('notifies listeners exactly once', () async {
      final storage = PairingStorage(_FakeSecureStorage());
      var notifications = 0;
      storage.addListener(() => notifications++);

      await storage.wipeAll();

      expect(notifications, 1);
    });
  });
}
