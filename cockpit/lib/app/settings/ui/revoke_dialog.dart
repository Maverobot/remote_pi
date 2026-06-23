import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/settings/ui/revoke_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Dialog de progresso do revoke: carregando enquanto sobe o `pi --mode rpc` e
/// roda `/remote-pi revoke`, depois sucesso/erro com botão "Ok". Recebe o
/// [RevokeController] por construtor (quem abre descarta ao fechar).
class RevokeDialog extends StatelessWidget {
  const RevokeDialog({super.key, required this.controller});

  final RevokeController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _dialog(context),
  );

  Widget _dialog(BuildContext context) {
    final ctrl = controller;
    final colors = context.colors;

    return AlertDialog(
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: switch (ctrl.stage) {
          RevokeStage.running => _running(context, ctrl),
          RevokeStage.done => _result(
            context,
            icon: Icons.check_circle_outline,
            color: colors.online,
            message: 'Device removed.',
          ),
          RevokeStage.failed => _result(
            context,
            icon: Icons.error_outline,
            color: colors.error,
            message: ctrl.error ?? 'Failed to revoke the device.',
          ),
        },
      ),
      actions: ctrl.stage == RevokeStage.running
          ? null
          : [
              PrimaryButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Ok'),
              ),
            ],
    );
  }

  Widget _running(BuildContext context, RevokeController ctrl) {
    final colors = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(size: 34),
        const SizedBox(height: 18),
        Text(
          ctrl.deviceName == null
              ? 'Revoking…'
              : 'Revoking ${ctrl.deviceName}…',
          textAlign: TextAlign.center,
          style: context.typo.body.copyWith(
            fontSize: 13.5,
            color: colors.text2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Connecting to the relay and removing access.',
          textAlign: TextAlign.center,
          style: context.typo.label.copyWith(color: colors.text3),
        ),
      ],
    );
  }

  Widget _result(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String message,
  }) {
    final colors = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 32, color: color),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: context.typo.body.copyWith(
            fontSize: 13.5,
            color: colors.text2,
          ),
        ),
      ],
    );
  }
}
