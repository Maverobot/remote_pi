import 'dart:convert';

import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Inline tool execution card that appears in the chat flow.
//
// Historically this widget rendered Allow/Deny buttons + a 60s countdown
// assuming the Pi paused execution until the user decided. With the current
// Claude SDK integration the pi-extension emits `tool_request` AFTER the
// SDK has already accepted the tool (`tool_execution_start` fires post
// auto-approval), so the buttons could only blink for a few hundred
// milliseconds before `tool_result` arrived — confusing UX with no real
// gating. The card is now purely informational.
//
// `onDecide` is kept on the API for forward compat — when the Pi adds a
// real approval pause we can re-enable the controls. Today it is unused.

class ToolRequestCard extends StatelessWidget {
  final ToolEvent tool;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String toolCallId, ApproveDecision decision)? onDecide;

  const ToolRequestCard({
    super.key,
    required this.tool,
    required this.expanded,
    required this.onToggle,
    this.onDecide,
  });

  /// Plan/32 — one color drives the whole card so the outcome is unmistakable:
  /// running → blue, done → green, failed → red, denied/expired → grey.
  Color _statusColor(BuildContext context) {
    final colors = context.colors;
    return switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => colors.accent,
      ToolEventStatus.completed => colors.success,
      ToolEventStatus.failed => colors.error,
      ToolEventStatus.denied || ToolEventStatus.expired => colors.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context);
    // Dim only the inert states (denied/expired); keep done/failed at full
    // opacity so their green/red read clearly.
    final dimmed =
        tool.status == ToolEventStatus.denied ||
        tool.status == ToolEventStatus.expired;

    return Opacity(
      opacity: dimmed ? 0.65 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: color, width: 1),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.13),
              blurRadius: 20,
              spreadRadius: 1,
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, color),
            if (expanded) ...[
              const SizedBox(height: 10),
              _buildCodeBlock(context),
              const SizedBox(height: 8),
              _buildOutcome(color),
              if (_hasResult)
                _buildOutputSection(
                  context,
                  'OUTPUT',
                  _payloadText(tool.result),
                ),
              if (tool.error?.isNotEmpty ?? false)
                _buildOutputSection(context, 'ERROR', tool.error!),
            ],
          ],
        ),
      ),
    );
  }

  bool get _hasResult => tool.result != null && tool.result != '';
  bool get _hasOutput => _hasResult || (tool.error?.isNotEmpty ?? false);

  String _inputText() {
    final args = tool.args;
    if (tool.tool.toLowerCase() == 'bash' && args is Map) {
      final command = args['command'];
      if (command is String) return command;
    }
    return _payloadText(args);
  }

  String _outputText() => [
    if (_hasResult) _payloadText(tool.result),
    if (tool.error?.isNotEmpty ?? false) tool.error!,
  ].join('\n');

  static String _payloadText(Object? value) => value is String
      ? value
      : const JsonEncoder.withIndent('  ').convert(value);

  Future<void> _copy(BuildContext context, String text, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not copy ${label.toLowerCase()}')),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Widget _buildOutputSection(BuildContext context, String label, String text) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: context.typo.monoSmall.copyWith(
                color: label == 'ERROR'
                    ? context.colors.error
                    : context.colors.muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(text, style: context.typo.mono),
          ],
        ),
      );

  Widget _buildHeader(BuildContext context, Color color) {
    final statusLabel = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => 'RUNNING',
      ToolEventStatus.completed => 'DONE',
      ToolEventStatus.failed => 'FAILED',
      ToolEventStatus.denied => 'DENIED',
      ToolEventStatus.expired => 'EXPIRED',
    };

    final preview = expanded ? '' : _formatPreview(tool.tool, tool.args);

    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            expanded: expanded,
            label:
                '${tool.tool}, ${expanded ? "expanded" : "collapsed"}, $statusLabel'
                '${preview.isEmpty ? "" : ", $preview"}',
            onTap: onToggle,
            excludeSemantics: true,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onToggle,
                excludeFromSemantics: true,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CustomPaint(
                            size: const Size(14, 14),
                            painter: _TerminalIconPainter(color: color),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tool.tool.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: kMonoFamily,
                                fontSize: 11.5,
                                color: color,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              fontFamily: kMonoFamily,
                              fontSize: 10,
                              color: color,
                              letterSpacing: 0.4,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            expanded ? Icons.expand_less : Icons.expand_more,
                            color: color,
                            size: 20,
                          ),
                        ],
                      ),
                      if (preview.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          preview,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: context.typo.monoSmall.copyWith(
                            color: context.colors.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox.square(
          dimension: 48,
          child: PopupMenuButton<_ToolCopyAction>(
            tooltip: 'Copy options',
            icon: Icon(Icons.more_vert, color: context.colors.text),
            onSelected: (action) {
              switch (action) {
                case _ToolCopyAction.input:
                  _copy(context, _inputText(), 'Input');
                case _ToolCopyAction.output:
                  _copy(context, _outputText(), 'Output');
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _ToolCopyAction.input,
                enabled: tool.args != null,
                child: Text(
                  'Copy input',
                  style: context.typo.monoSmall.copyWith(
                    color: tool.args != null
                        ? context.colors.accent
                        : context.colors.muted,
                  ),
                ),
              ),
              PopupMenuItem(
                value: _ToolCopyAction.output,
                enabled: _hasOutput,
                child: Text(
                  'Copy output',
                  style: context.typo.monoSmall.copyWith(
                    color: _hasOutput
                        ? context.colors.accent
                        : context.colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCodeBlock(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final content = _buildToolSummary(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r'$ ', style: typo.mono.copyWith(color: colors.muted)),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildToolSummary(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final display = _formatToolDisplay(tool.tool, tool.args);
    if (display == null) {
      return Text(_formatArgs(tool.tool, tool.args), style: typo.mono);
    }

    return Text.rich(
      TextSpan(
        style: typo.mono,
        children: [
          TextSpan(text: display.command),
          for (final line in display.lines) ...[
            const TextSpan(text: '\n'),
            TextSpan(
              text: line.text,
              style: TextStyle(color: line.color(colors)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutcome(Color color) {
    final text = switch (tool.status) {
      ToolEventStatus.pending || ToolEventStatus.allowed => '⏳ Running…',
      ToolEventStatus.completed => '✓ Done',
      ToolEventStatus.failed => '✗ ${tool.error ?? "Failed"}',
      ToolEventStatus.denied => '✗ ${tool.error ?? "Denied"}',
      ToolEventStatus.expired => '✗ Expired',
    };
    return Text(
      text,
      style: TextStyle(fontFamily: kMonoFamily, fontSize: 12, color: color),
    );
  }

  static String _formatPreview(String tool, dynamic args) {
    if (args is! Map) return '';
    final value = switch (tool.toLowerCase()) {
      'bash' => _stringArg(args, const ['command']),
      'read' ||
      'edit' ||
      'write' => _stringArg(args, const ['file_path', 'path']),
      _ => '',
    };
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _formatArgs(String tool, dynamic args) {
    if (args == null) return '';
    final normalizedTool = tool.toLowerCase();
    if (args is Map) {
      return switch (normalizedTool) {
        'bash' => (args['command'] as String?) ?? '',
        'edit' || 'write' =>
          '$normalizedTool ${_stringArg(args, const ['file_path', 'path'])}',
        _ => args.entries.map((e) => '${e.key}=${e.value}').join(' '),
      };
    }
    return args.toString();
  }

  static _ToolDisplay? _formatToolDisplay(String tool, dynamic args) {
    if (args is! Map) return null;
    return switch (tool.toLowerCase()) {
      'edit' => _formatEditDisplay(args),
      _ => null,
    };
  }

  static _ToolDisplay? _formatEditDisplay(Map args) {
    final filePath = _stringArg(args, const ['file_path', 'path']);
    final lines = <_DiffLine>[];
    final hunks = args['hunks'];
    if (hunks is! Iterable) return null;

    for (final hunk in hunks) {
      if (hunk is! Map || hunk['lines'] is! Iterable) continue;
      if (lines.isNotEmpty) lines.add(_DiffLine.context('      ...'));
      for (final rawLine in hunk['lines'] as Iterable) {
        if (rawLine is! Map) continue;
        final text = _lineText(rawLine);
        switch (rawLine['kind']) {
          case 'context':
            lines.add(_DiffLine.context(text));
          case 'remove':
            lines.add(_DiffLine.removed(text));
          case 'add':
            lines.add(_DiffLine.added(text));
          case 'ellipsis':
            lines.add(_DiffLine.context('      ...'));
        }
      }
    }

    if (lines.isEmpty) return null;
    return _ToolDisplay(command: 'edit $filePath', lines: lines);
  }

  static String _lineText(Map rawLine) {
    final sign = switch (rawLine['kind']) {
      'remove' => '-',
      'add' => '+',
      _ => ' ',
    };
    final lineNumber = rawLine['oldLine'] ?? rawLine['newLine'];
    final number = lineNumber is int ? lineNumber.toString().padLeft(3) : '   ';
    return '$sign $number ${rawLine['text'] ?? ''}';
  }

  static String _stringArg(Map args, List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String) return value;
    }
    return '';
  }
}

enum _ToolCopyAction { input, output }

class _ToolDisplay {
  final String command;
  final List<_DiffLine> lines;

  const _ToolDisplay({required this.command, required this.lines});
}

class _DiffLine {
  final String text;
  final Color Function(AppColors colors) color;

  const _DiffLine._(this.text, this.color);

  factory _DiffLine.removed(String text) =>
      _DiffLine._(text, (colors) => colors.error);

  factory _DiffLine.added(String text) =>
      _DiffLine._(text, (colors) => colors.success);

  factory _DiffLine.context(String text) =>
      _DiffLine._(text, (colors) => colors.text);
}

// Minimal terminal icon (rectangle + > and —)
class _TerminalIconPainter extends CustomPainter {
  final Color color;
  const _TerminalIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 1, size.width - 1, size.height - 2),
        const Radius.circular(1.6),
      ),
      paint,
    );
    final path = Path()
      ..moveTo(3, 4.5)
      ..lineTo(5.5, 7)
      ..lineTo(3, 9.5);
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(6.5, size.height / 2),
      Offset(size.width - 2, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TerminalIconPainter old) => old.color != color;
}
