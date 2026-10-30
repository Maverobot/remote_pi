import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ---------------------------------------------------------------------------
// UserBubble — right-aligned dark card
// ---------------------------------------------------------------------------

class UserBubble extends StatelessWidget {
  final UserMsg message;
  const UserBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    // Plan/24-fix-app-source-of-truth: render the lifecycle stage of
    // the bubble. `pending` (sent over WS, Pi hasn't echoed yet) gets
    // reduced opacity + a small spinner; `failed` (no echo in 15s) gets
    // a red exclamation badge so the user knows to retry.
    final isPending = message.status == UserMsgStatus.pending;
    final isFailed = message.status == UserMsgStatus.failed;
    final isSteering = message.steering;
    // When images are attached the bubble renders every thumbnail in order;
    // otherwise it uses the existing text card.
    final images = message.images;
    final colors = context.colors;
    final typo = context.typo;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Opacity(
              opacity: isPending ? 0.6 : 1.0,
              child: images.isNotEmpty
                  ? ImageBubble(
                      images: images,
                      caption: message.text,
                      isFailed: isFailed,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: colors.userBubble,
                        borderRadius: BorderRadius.circular(12),
                        border: isFailed
                            ? Border.all(color: colors.error, width: 1)
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 10,
                      ),
                      // Selectable so the user can copy their own message (the
                      // agent reply is already selectable via AgentMarkdown).
                      child: SelectableText(
                        message.text,
                        style: typo.sansBody.copyWith(color: colors.text),
                      ),
                    ),
            ),
            if (isPending || isSteering || isFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isPending || isSteering) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          color: colors.muted,
                          strokeWidth: 1.2,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isSteering ? 'steering…' : 'sending…',
                        style: typo.sansBody.copyWith(
                          color: colors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ] else ...[
                      Icon(
                        LucideIcons.circleAlert,
                        size: 12,
                        color: colors.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'not delivered',
                        style: typo.sansBody.copyWith(
                          color: colors.error,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CompactionBubble — centered system card (plan/32)
// ---------------------------------------------------------------------------

/// A system message distinct from user/assistant: shows that the Pi compacted
/// the context, with the recap summary and pre-compaction token count. Mirrors
/// the TUI's CompactionSummaryMessageComponent.
class CompactionBubble extends StatelessWidget {
  final CompactionMsg message;
  final bool expanded;
  final VoidCallback onToggle;
  const CompactionBubble(
    this.message, {
    super.key,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = message.tokensBefore;
    final summary = message.summary;
    final colors = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (summary.isNotEmpty)
                Semantics(
                  button: true,
                  expanded: expanded,
                  label:
                      'Context compacted, ${expanded ? "expanded" : "collapsed"}'
                      '${tokens == null ? "" : ", ~$tokens tokens"}',
                  onTap: onToggle,
                  excludeSemantics: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: onToggle,
                      excludeFromSemantics: true,
                      borderRadius: BorderRadius.circular(8),
                      child: _buildHeader(context),
                    ),
                  ),
                )
              else
                _buildHeader(context),
              if (expanded && summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  summary,
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 12,
                    color: colors.muted2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.colors;
    final tokens = message.tokensBefore;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          Icon(LucideIcons.check, size: 13, color: colors.success),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Context compacted',
                  style: context.typo.mono.copyWith(
                    fontSize: 12,
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (tokens != null)
                  Text(
                    '~$tokens tokens',
                    style: context.typo.monoSmall.copyWith(color: colors.muted),
                  ),
              ],
            ),
          ),
          if (message.summary.isNotEmpty) ...[
            const SizedBox(width: 8),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              color: colors.muted,
              size: 20,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AssistantBubble — left-aligned monospace text
// ---------------------------------------------------------------------------

class AssistantBubble extends StatelessWidget {
  final AssistantMsg message;
  const AssistantBubble(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    // Plan/32b — agent output is rendered as Markdown (GFM + code blocks),
    // spanning the FULL content width (the message list already pads 16px on
    // each side) — unlike the user's right-aligned chat bubble, which stays
    // capped. Selectable so prose/code can be copied.
    return SizedBox(
      width: double.infinity,
      child: AgentMarkdown(message.text, selectable: true),
    );
  }
}
