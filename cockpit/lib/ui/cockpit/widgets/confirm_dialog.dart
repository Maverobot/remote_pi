import 'package:cockpit/ui/core/themes/themes.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Cor do barrier (escurece o fundo) — o `showDialog` do shadcn usa barrier
/// transparente por padrão; aqui damos o leve dim que o modal pedia.
const Color _barrier = Color(0x99000000);

/// Dialog informativo genérico (tema do cockpit) — só botão "OK".
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required String message,
  String okLabel = 'Got it',
}) {
  return showDialog<void>(
    context: context,
    barrierColor: _barrier,
    builder: (context) {
      final colors = context.colors;
      return AlertDialog(
        title: Text(
          title,
          style: context.typo.title.copyWith(fontSize: 15, color: colors.text),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            message,
            style: context.typo.body.copyWith(
              fontSize: 13.5,
              color: colors.text2,
            ),
          ),
        ),
        actions: [
          PrimaryButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(okLabel),
          ),
        ],
      );
    },
  );
}

/// Dialog de confirmação genérico (tema do cockpit). Devolve `true` se confirmar.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: _barrier,
    builder: (context) {
      final colors = context.colors;
      return AlertDialog(
        title: Text(
          title,
          style: context.typo.title.copyWith(fontSize: 15, color: colors.text),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            message,
            style: context.typo.body.copyWith(
              fontSize: 13.5,
              color: colors.text2,
            ),
          ),
        ),
        actions: [
          OutlineButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          if (danger)
            DestructiveButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            )
          else
            PrimaryButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
        ],
      );
    },
  );
  return result ?? false;
}
