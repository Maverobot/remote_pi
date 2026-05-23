import 'dart:async';
import 'dart:typed_data';

import 'package:app/pairing/storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:remote_pi_identity/remote_pi_identity.dart';

/// Outcome of a `bridge.boot()` call. The router uses this to decide
/// between "show sync-required gate" and "boot normally".
sealed class OwnerIdentityBootResult {
  const OwnerIdentityBootResult();
}

/// Platform key-sync surface is off — caller must surface the
/// platform-specific config instructions and *not* generate a local
/// identity (would silently diverge with sync later).
final class SyncUnavailableResult extends OwnerIdentityBootResult {
  const SyncUnavailableResult();
}

/// Either loaded from sync or freshly generated. Carries the
/// 32-byte public key so callers can stash it before challenge-response
/// time; the private key stays on-disk to avoid keeping it in heap.
final class IdentityReady extends OwnerIdentityBootResult {
  final OwnerIdentity identity;
  /// True when this run generated the keypair instead of loading it.
  /// Surfaced for telemetry / "fresh install" UX decisions.
  final bool generated;
  const IdentityReady(this.identity, {required this.generated});
}

/// Bridge between the `remote_pi_identity` plugin and the rest of the
/// app. Responsibilities:
///
/// - Boot-time decision: sync available? identity present?
/// - `currentIdentity` getter for callers that need the Owner-sk for
///   relay challenge-response (production transport factory).
/// - Watch-on-sync hook: when the platform delivers a different
///   Owner-key (restored on a new device, owner re-installed elsewhere),
///   wipe local peer/room caches because the previous device's
///   `remote_epk` set is meaningless against a fresh identity.
class OwnerIdentityBridge extends ChangeNotifier {
  final OwnerIdentityStore _store;
  final PairingStorage _pairing;
  final Ed25519 _ed25519 = Ed25519();

  OwnerIdentity? _current;
  StreamSubscription<OwnerIdentity>? _watchSub;
  bool _disposed = false;

  OwnerIdentityBridge(this._store, this._pairing);

  OwnerIdentity? get currentIdentity => _current;

  /// Public key of the currently-loaded Owner identity (or null when
  /// the bridge hasn't booted yet). Surfaces this for the router's
  /// guard logic.
  Uint8List? get currentOwnerPk => _current?.ownerPk;

  /// Check sync availability, load (or generate) the Owner identity.
  /// Idempotent — repeated calls are cheap once `_current` is populated.
  Future<OwnerIdentityBootResult> boot() async {
    if (!await _store.isSyncAvailable()) {
      debugPrint('[owner-bridge] boot: sync UNAVAILABLE');
      return const SyncUnavailableResult();
    }
    try {
      final loaded = await _store.load();
      if (loaded != null) {
        _current = loaded;
        debugPrint('[owner-bridge] boot: loaded existing identity');
        return IdentityReady(loaded, generated: false);
      }
    } on IdentityStoreError catch (e) {
      debugPrint('[owner-bridge] boot: load failed ($e) — treating as fresh');
    }

    final generated = await _generateAndSave();
    _current = generated;
    debugPrint('[owner-bridge] boot: generated NEW identity');
    return IdentityReady(generated, generated: true);
  }

  Future<OwnerIdentity> _generateAndSave() async {
    final kp = await _ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    final id = OwnerIdentity(
      ownerPk: Uint8List.fromList(pub.bytes),
      ownerSk: Uint8List.fromList(priv),
    );
    await _store.save(id);
    return id;
  }

  /// Rehydrate a `SimpleKeyPair` from the cached Owner identity. Used
  /// at challenge-response time — callers must have already gone
  /// through [boot] (otherwise [currentIdentity] would still be null
  /// and this throws `StateError`).
  Future<SimpleKeyPair> requireKeyPair() async {
    final id = _current;
    if (id == null) {
      throw StateError(
        'OwnerIdentityBridge.requireKeyPair() called before boot() — '
        'router should have gated this path on IdentityReady.',
      );
    }
    return _ed25519.newKeyPairFromSeed(id.ownerSk);
  }

  /// Subscribe to platform sync events. When the incoming Owner-pk
  /// differs from [_current], the bridge:
  ///   1. wipes [PairingStorage] (peers + rooms) — stale handles.
  ///   2. caches the new identity.
  ///   3. calls [onReset] so the host can force a fresh router boot.
  ///
  /// Same-pk events are dropped — re-saves of identical content (echo
  /// from our own write) shouldn't reset state.
  void startWatching({required Future<void> Function() onReset}) {
    _watchSub?.cancel();
    _watchSub = _store.watch().listen((incoming) async {
      final current = _current;
      if (current != null && _bytesEqual(current.ownerPk, incoming.ownerPk)) {
        return;
      }
      debugPrint(
        '[owner-bridge] watch: Owner-pk changed via sync — wiping peers',
      );
      _current = incoming;
      await _pairing.wipeAll();
      await onReset();
    }, onError: (Object e) {
      debugPrint('[owner-bridge] watch error: $e');
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watchSub?.cancel();
    _watchSub = null;
    super.dispose();
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
