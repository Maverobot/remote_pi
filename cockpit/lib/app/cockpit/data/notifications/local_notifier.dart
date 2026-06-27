import 'package:cockpit/app/cockpit/domain/contracts/notifier.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:media_kit/media_kit.dart';

/// Notificações nativas via `flutter_local_notifications` (macOS first) + chime
/// in-app via `media_kit` (cross-platform: macOS/Windows/Linux).
class LocalNotifier implements Notifier {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  int _id = 0;

  /// Player dedicado ao chime curto, reusado a cada toque (re-`open` reinicia).
  Player? _chime;

  @override
  Future<void> init() async {
    _chime = Player();
    const settings = InitializationSettings(
      macOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
        // Desktop app está sempre em foreground: sem esses flags o
        // UNUserNotificationCenter suprime o banner silenciosamente.
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      ),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    );
    await _plugin.initialize(settings);
  }

  @override
  Future<void> agentFinished({
    required String agentName,
    required String workspace,
  }) async {
    final subtitle = workspace.isEmpty ? agentName : '$agentName · $workspace';
    await _plugin.show(
      _id++,
      'Agent finished',
      subtitle,
      const NotificationDetails(
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        linux: LinuxNotificationDetails(),
      ),
    );
  }

  @override
  Future<void> playTurnChime() async {
    try {
      await _chime?.open(Media('asset:///assets/sounds/turn_done.wav'));
    } catch (_) {
      // som é best-effort: nunca quebra o fluxo de fim de turno.
    }
  }
}
