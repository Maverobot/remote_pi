import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Read-only history from the retired pi-ask-user integration. New interactive
/// prompts use the upstream pi-ask extension UI sheet instead.
class AskUserPromptCard extends StatelessWidget {
  final AskUserPromptMsg prompt;

  const AskUserPromptCard({super.key, required this.prompt});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final resolved = prompt.resolved || prompt.cancelled;
    final border = resolved && !prompt.cancelled
        ? colors.success
        : colors.muted;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'ASK_USER',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 11,
                  color: border,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              Text(
                prompt.cancelled
                    ? 'Cancelled'
                    : prompt.resolved
                    ? 'Answered'
                    : 'Archived',
                style: TextStyle(color: border),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            prompt.question,
            style: TextStyle(fontFamily: kMonoFamily, color: colors.text),
          ),
          if (prompt.context.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              prompt.context,
              style: TextStyle(fontSize: 12, color: colors.muted2),
            ),
          ],
          if (prompt.answerLabel != null && prompt.answerLabel!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              prompt.answerLabel!,
              style: TextStyle(fontSize: 12, color: colors.text),
            ),
          ],
          if (!resolved)
            for (final option in prompt.options) ...[
              const SizedBox(height: 8),
              Text(option.title),
              if (option.description?.isNotEmpty ?? false)
                Text(
                  option.description!,
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
            ],
          const SizedBox(height: 8),
          Text(
            'Legacy prompt — read-only.',
            style: TextStyle(fontSize: 12, color: colors.muted2),
          ),
        ],
      ),
    );
  }
}
