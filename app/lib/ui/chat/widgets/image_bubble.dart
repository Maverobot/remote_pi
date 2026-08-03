import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Ordered static image thumbnails plus an optional caption inside a user
/// bubble. There is intentionally no full-screen or tap/zoom behavior.
class ImageBubble extends StatelessWidget {
  const ImageBubble({
    super.key,
    required this.images,
    this.caption = '',
    this.isFailed = false,
  }) : assert(images.length > 0);

  final List<MessageImage> images;
  final String caption;
  final bool isFailed;

  /// Cap each thumbnail height; width follows the bubble's 300px max.
  static const double maxHeight = 220;

  @override
  Widget build(BuildContext context) {
    final trimmedCaption = caption.trim();
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.userBubble,
        borderRadius: BorderRadius.circular(12),
        border: isFailed ? Border.all(color: colors.error, width: 1) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < images.length; index++) ...[
            if (index > 0) Divider(height: 1, color: colors.border),
            _DecodedMessageImage(
              key: Key('message-image-$index'),
              image: images[index],
            ),
          ],
          if (trimmedCaption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              child: Text(
                trimmedCaption,
                style: context.typo.sansBody.copyWith(color: colors.text),
              ),
            ),
        ],
      ),
    );
  }
}

class _DecodedMessageImage extends StatefulWidget {
  const _DecodedMessageImage({super.key, required this.image});

  final MessageImage image;

  @override
  State<_DecodedMessageImage> createState() => _DecodedMessageImageState();
}

class _DecodedMessageImageState extends State<_DecodedMessageImage> {
  late Uint8List _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _decode(widget.image.data);
  }

  @override
  void didUpdateWidget(_DecodedMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.data != widget.image.data) {
      _bytes = _decode(widget.image.data);
    }
  }

  static Uint8List _decode(String data) {
    try {
      return base64Decode(data);
    } catch (_) {
      return Uint8List(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: ImageBubble.maxHeight),
      child: _bytes.isEmpty
          ? _broken(context)
          : Image.memory(_bytes, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }

  Widget _broken(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 120,
      color: colors.codeBg,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, color: colors.muted, size: 28),
    );
  }
}
