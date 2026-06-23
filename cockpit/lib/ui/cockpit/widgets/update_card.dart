import 'package:cockpit/ui/cockpit/viewmodels/update_viewmodel.dart';
import 'package:cockpit/ui/core/themes/themes.dart';
import 'package:cockpit/ui/core/widgets/hover_tap.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Mini update card at the bottom of the rail — above the machine name. Only
/// renders when the [UpdateViewModel] has a new, non-dismissed version.
/// Clicking downloads the artifact; the X dismisses it (persisted per version).
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<UpdateViewModel>();
    final info = vm.available;
    if (info == null) return const SizedBox.shrink();

    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: HoverTap(
        color: colors.panel2,
        hoverColor: colors.panel3,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.accent.withValues(alpha: 0.5)),
        onTap: () => context.read<UpdateViewModel>().download(),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Row(
          children: [
            Icon(Icons.system_update_alt, size: 15, color: colors.accentText),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Update available',
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.label.copyWith(
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'v${info.version} — click to download',
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.label.copyWith(color: colors.text3),
                  ),
                ],
              ),
            ),
            Tooltip(
              tooltip: (context) =>
                  const TooltipContainer(child: Text('Dismiss')),
              child: HoverTap(
                onTap: () => context.read<UpdateViewModel>().dismiss(),
                borderRadius: BorderRadius.circular(5),
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: colors.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
