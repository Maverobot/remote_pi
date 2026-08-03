import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

/// Pick camera/gallery images and compress each one (JPEG, longest side
/// ≤1568px, q80) entirely on-device before it travels inline on a
/// `user_message`. No file is uploaded out-of-band.
///
/// The plugin calls go through the [ImagePickerBackend] seam so the
/// pick + iterative size-ceiling logic is unit-testable without a device.
abstract class IImagePickerService {
  /// Capture a photo. Returns null if the user cancelled. Throws
  /// [ImagePermissionDeniedException] when camera permission is denied (#10).
  Future<PickedImage?> pickFromCamera();

  /// Pick up to [limit] images from the gallery (system PHPicker / Photo
  /// Picker — no permission). Returns an empty list if the user cancelled.
  Future<List<PickedImage>> pickFromGallery({int limit = 10});
}

/// A picked + compressed image ready for preview and sending. Bytes are raw
/// (not base64) so the composer preview renders them directly; the send path
/// base64-encodes into a `MessageImage`.
class PickedImage {
  final Uint8List bytes;
  final String mime;
  const PickedImage({required this.bytes, required this.mime});
}

/// Thrown when the camera permission was denied — the UI guides the user to
/// system Settings (reuses the plan-29 `app_settings` affordance).
class ImagePermissionDeniedException implements Exception {
  const ImagePermissionDeniedException();
  @override
  String toString() => 'ImagePermissionDeniedException';
}

/// Compression exhausted its bounded retries without meeting the transport
/// size ceiling. The attachment ViewModel surfaces this through pickFailed.
class ImageTooLargeException implements Exception {
  const ImageTooLargeException();
  @override
  String toString() => 'ImageTooLargeException';
}

class ImagePickerService implements IImagePickerService {
  ImagePickerService([ImagePickerBackend? backend])
    : _backend = backend ?? PlatformImagePickerBackend();

  final ImagePickerBackend _backend;

  /// Longest side of the compressed image (decision #5).
  static const int _maxSide = 1568;

  /// Initial JPEG quality (decision #5).
  static const int _quality = 80;

  /// Safety ceiling — re-compress harder if we somehow blow past this
  /// (rare; the defaults land ~150–400 KB).
  static const int _ceilingBytes = 1500 * 1024;

  /// Max extra passes before rejecting an image that remains over the cap.
  static const int _maxExtraPasses = 3;

  @override
  Future<PickedImage?> pickFromCamera() async {
    final path = await _backend.pick(ImageSourceKind.camera);
    return path == null ? null : _compress(path);
  }

  @override
  Future<List<PickedImage>> pickFromGallery({int limit = 10}) async {
    if (limit <= 0) return const [];
    if (limit == 1) {
      final path = await _backend.pick(ImageSourceKind.gallery);
      return path == null ? const [] : [await _compress(path)];
    }
    final paths = await _backend.pickMultiple(limit: limit);
    final images = <PickedImage>[];
    for (final path in paths) {
      images.add(await _compress(path));
    }
    return List.unmodifiable(images);
  }

  Future<PickedImage> _compress(String path) async {
    var side = _maxSide;
    var quality = _quality;
    var bytes = await _backend.compress(path, maxSide: side, quality: quality);

    // Iterative ceiling: shrink dimension + quality until under the cap (or
    // we run out of passes). Practically never fires.
    var pass = 0;
    while (bytes.length > _ceilingBytes && pass < _maxExtraPasses) {
      pass++;
      quality = (quality - 15).clamp(35, 100);
      side = (side * 0.85).round();
      bytes = await _backend.compress(path, maxSide: side, quality: quality);
    }

    if (bytes.length > _ceilingBytes) {
      throw const ImageTooLargeException();
    }
    return PickedImage(bytes: bytes, mime: 'image/jpeg');
  }
}

// ---------------------------------------------------------------------------
// Backend seam
// ---------------------------------------------------------------------------

enum ImageSourceKind { camera, gallery }

/// Thin seam over `image_picker` + `flutter_image_compress`.
abstract class ImagePickerBackend {
  /// Pick one camera or gallery file; returns its path, or null if cancelled.
  /// Throws [ImagePermissionDeniedException] when access is denied.
  Future<String?> pick(ImageSourceKind source);

  /// Pick gallery files in the platform picker's stable result order.
  Future<List<String>> pickMultiple({required int limit});

  /// Compress [path] to JPEG bounded by [maxSide]px at [quality].
  Future<Uint8List> compress(
    String path, {
    required int maxSide,
    required int quality,
  });
}

class PlatformImagePickerBackend implements ImagePickerBackend {
  PlatformImagePickerBackend([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<String?> pick(ImageSourceKind source) async {
    try {
      final file = await _picker.pickImage(
        source: source == ImageSourceKind.camera
            ? ImageSource.camera
            : ImageSource.gallery,
      );
      return file?.path;
    } on PlatformException catch (e) {
      if (_isPermissionDenied(e)) {
        throw const ImagePermissionDeniedException();
      }
      rethrow;
    }
  }

  @override
  Future<List<String>> pickMultiple({required int limit}) async {
    try {
      final files = await _picker.pickMultiImage(limit: limit);
      return files.map((file) => file.path).toList(growable: false);
    } on PlatformException catch (e) {
      if (_isPermissionDenied(e)) {
        throw const ImagePermissionDeniedException();
      }
      rethrow;
    }
  }

  static bool _isPermissionDenied(PlatformException error) =>
      error.code.contains('access_denied') || error.code.contains('denied');

  @override
  Future<Uint8List> compress(
    String path, {
    required int maxSide,
    required int quality,
  }) async {
    final out = await FlutterImageCompress.compressWithFile(
      path,
      minWidth: maxSide,
      minHeight: maxSide,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    // Fallback: if the platform compressor returns null (unsupported source
    // format), surface an empty result so the caller can no-op gracefully.
    return out ?? Uint8List(0);
  }
}
