import 'package:app/config/dependencies.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/home/home_page.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/onboarding/onboarding_page.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/pairing_page.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/sync_required/sync_required_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// Boot decision is async — _BootState is a ChangeNotifier used as
// refreshListenable so the router redirects once the storage check finishes.
class _BootState extends ChangeNotifier {
  bool _ready = false;
  bool _hasPeer = false;
  bool _onboarded = false;
  bool _syncAvailable = true;

  bool get ready => _ready;
  bool get hasPeer => _hasPeer;
  bool get onboarded => _onboarded;
  bool get syncAvailable => _syncAvailable;

  Future<void> load(
    PairingStorage storage,
    ConnectionManager conn,
    Preferences prefs,
    OwnerIdentityBridge ownerBridge,
  ) async {
    await prefs.load();

    // Plan 23 — block bootstrap until the platform's key-sync surface
    // (iCloud Keychain / Block Store) is usable AND we have an
    // Owner-key (loaded or freshly generated). If sync is off, the
    // router redirects to /sync-required and the user retries from
    // there once they flip the toggle in Settings.
    final ownerResult = await ownerBridge.boot();
    if (ownerResult is SyncUnavailableResult) {
      _syncAvailable = false;
      _ready = true;
      notifyListeners();
      return;
    }
    _syncAvailable = true;

    final peers = await storage.listPeers();
    _hasPeer = peers.isNotEmpty;
    // Plan 14: a user who already has a peer is implicitly onboarded —
    // they paired in an earlier app version that predates the
    // onboarding flow. Auto-flip the flag so they don't re-run it.
    if (_hasPeer && !prefs.onboardingCompleted) {
      await prefs.setOnboardingCompleted(true);
    }
    _onboarded = prefs.onboardingCompleted;
    _ready = true;
    notifyListeners();
    // Plano 13: `Preferences.selectedPeerEpk` is the authoritative
    // pointer to the peer the user wants connected. On a fresh install
    // it's null — default to `peers.first` so subsequent boot()s have a
    // stable target and the user lands on a deterministic chat.
    if (_hasPeer) {
      var selected = prefs.selectedPeerEpk;
      if (selected == null) {
        selected = peers.first.remoteEpk;
        await prefs.setSelectedPeerEpk(selected);
      } else if (!peers.any((p) => p.remoteEpk == selected)) {
        // Selected peer was revoked / no longer in storage — fall back.
        selected = peers.first.remoteEpk;
        await prefs.setSelectedPeerEpk(selected);
      }
      // ignore: unawaited_futures
      conn.boot(preferredEpk: selected);
    }
  }

  /// Plan 23 — invoked by the OwnerIdentityBridge watch listener when
  /// platform sync delivers a different Owner-pk. We reset to the
  /// "no-state" view; the next `load()` call (triggered when the user
  /// returns to /boot) will repopulate from the freshly-wiped storage.
  void onOwnerKeyReplaced() {
    _ready = false;
    _hasPeer = false;
    _onboarded = false;
    notifyListeners();
  }
}

GoRouter buildRouter(
  PairingStorage storage,
  ConnectionManager conn,
  Preferences prefs,
  OwnerIdentityBridge ownerBridge,
) {
  final boot = _BootState();
  boot.load(storage, conn, prefs, ownerBridge);

  // Plan 23 — watch for Owner-key drift on the sync surface. When the
  // platform delivers a different keypair (restored on a new device,
  // user wiped and re-installed elsewhere), the bridge wipes peers/rooms
  // and we reset the boot state so the router redirects through /boot.
  ownerBridge.startWatching(onReset: () async {
    await conn.disconnect();
    boot.onOwnerKeyReplaced();
    await boot.load(storage, conn, prefs, ownerBridge);
  });

  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: boot,
    redirect: (context, state) {
      if (!boot.ready) return '/boot';
      // Sync-required gate is sticky until the user toggles iCloud /
      // Backup on and taps "Check again". Don't redirect away from
      // /sync-required while the bridge still reports unavailable.
      if (!boot.syncAvailable) {
        return state.uri.path == '/sync-required' ? null : '/sync-required';
      }
      if (state.uri.path == '/sync-required') {
        return boot.hasPeer ? '/home' : '/onboarding';
      }
      if (state.uri.path == '/boot') {
        // No peer == no app surface to render. Always route to
        // /onboarding when peers are empty — this covers both the
        // first-install case AND the "user revoked everything"
        // case. The `onboardingCompleted` flag is preserved for
        // analytics / migration purposes but no longer gates the
        // redirect (was confusing: after revoke the app would land
        // on a near-empty /home with just a Scan QR button instead
        // of the full onboarding).
        return boot.hasPeer ? '/home' : '/onboarding';
      }
      return null;
    },
    routes: [
      // Splash while boot.load() is in flight
      GoRoute(
        path: '/boot',
        builder: (ctx, st) => const _BootSplash(),
      ),

      // Plan 23 — first-launch gate when iCloud Keychain / Google
      // Backup is off. Sticky route: redirect keeps the user here
      // until the bridge reports sync available.
      GoRoute(
        path: '/sync-required',
        builder: (ctx, st) => const SyncRequiredPage(),
      ),

      // Home — list of paired sessions, entry point post-boot
      GoRoute(
        path: '/home',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<HomeViewModel>()],
          child: const HomePage(),
        ),
      ),

      // QR pairing flow
      GoRoute(
        path: '/pair',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<PairingViewModel>()],
          child: const PairingPage(),
        ),
      ),

      // Onboarding (plan 14) — 3-step flow shown when the app has
      // never been paired AND the user hasn't opted out. Provides
      // both OnboardingViewModel (state machine) AND PairingViewModel
      // (step 3 embeds the QR scanner reusing existing pair flow).
      GoRoute(
        path: '/onboarding',
        builder: (ctx, st) => MultiProvider(
          providers: [
            ViewmodelProvider<OnboardingViewModel>(),
            ViewmodelProvider<PairingViewModel>(),
          ],
          child: const OnboardingPage(),
        ),
      ),

      // Chat screen (entered by tapping a session in /home)
      GoRoute(
        path: '/chat',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<ChatViewModel>()],
          child: const ChatPage(),
        ),
      ),

      // Settings (entered from /home menu)
      GoRoute(
        path: '/settings',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<SettingsViewModel>()],
          child: const SettingsPage(),
        ),
      ),
    ],
  );
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF000000),
      body: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            color: Color(0xFF00D4FF),
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }
}
