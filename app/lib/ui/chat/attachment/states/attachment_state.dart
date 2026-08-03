import 'package:app/data/images/image_picker_service.dart';

/// Composer attachment state for an ordered image collection.
///
/// [visionSupported] is tri-state: `true`/`false` once the model catalogue is
/// known, `null` while unknown (don't gate yet). Every exposed image list is
/// immutable so a state emission is a complete snapshot.
sealed class AttachmentState {
  const AttachmentState({
    required this.visionSupported,
    this.images = const [],
  });

  /// Whether the active model accepts images. `null` = not yet known.
  final bool? visionSupported;

  final List<PickedImage> images;

  /// Gate the attach affordance only when we *know* vision is unsupported.
  bool get attachBlockedByVision => visionSupported == false;
}

/// No image attached; composer behaves as text/voice.
final class AttachmentEmpty extends AttachmentState {
  const AttachmentEmpty({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentEmpty && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// A pick is in flight. Existing images remain visible and are preserved if
/// the new pick is cancelled or fails.
final class AttachmentPicking extends AttachmentState {
  AttachmentPicking({required List<PickedImage> images, super.visionSupported})
    : super(images: List.unmodifiable(images));

  @override
  bool operator ==(Object other) =>
      other is AttachmentPicking &&
      _sameImageInstances(other.images, images) &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(images.map(identityHashCode)),
    visionSupported,
  );
}

/// One or more images are attached and previewed in the composer.
final class AttachmentAttached extends AttachmentState {
  AttachmentAttached({required List<PickedImage> images, super.visionSupported})
    : assert(images.isNotEmpty),
      super(images: List.unmodifiable(images));

  @override
  bool operator ==(Object other) =>
      other is AttachmentAttached &&
      _sameImageInstances(other.images, images) &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(images.map(identityHashCode)),
    visionSupported,
  );
}

bool _sameImageInstances(List<PickedImage> left, List<PickedImage> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

/// One-shot hints the composer asks the host page to surface.
enum AttachHint {
  /// Camera permission denied — guide to system Settings.
  cameraPermissionDenied,

  /// Pick/compress failed for some other reason.
  pickFailed,

  /// The composer reached its hard ten-image limit.
  imageLimitReached,
}
