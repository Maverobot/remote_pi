// Plan/30 — ImagePickerService pick + iterative size-ceiling logic, via the
// ImagePickerBackend seam (no plugins / device).

import 'dart:typed_data';

import 'package:app/data/images/image_picker_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements ImagePickerBackend {
  String? path = '/tmp/pic.jpg'; // null → camera cancelled
  List<String> galleryPaths = ['/tmp/pic.jpg'];
  bool denied = false;

  /// Bytes returned per compress pass, in order. The last value repeats.
  List<int> sizes = [200 * 1024];
  final List<({String path, int side, int quality})> calls = [];
  ImageSourceKind? pickedSource;
  int? pickedLimit;

  @override
  Future<String?> pick(ImageSourceKind source) async {
    pickedSource = source;
    if (denied) throw const ImagePermissionDeniedException();
    return path;
  }

  @override
  Future<List<String>> pickMultiple({required int limit}) async {
    if (limit < 2) {
      throw ArgumentError.value(limit, 'limit', 'cannot be lower than 2');
    }
    pickedSource = ImageSourceKind.gallery;
    pickedLimit = limit;
    return galleryPaths.take(limit).toList();
  }

  @override
  Future<Uint8List> compress(
    String path, {
    required int maxSide,
    required int quality,
  }) async {
    calls.add((path: path, side: maxSide, quality: quality));
    final idx = calls.length - 1;
    final n = idx < sizes.length ? sizes[idx] : sizes.last;
    return Uint8List(n);
  }
}

void main() {
  test('gallery pick under the ceiling compresses once', () async {
    final backend = _FakeBackend()..sizes = [180 * 1024];
    final svc = ImagePickerService(backend);

    final result = await svc.pickFromGallery();
    expect(result, hasLength(1));
    expect(result.single.mime, 'image/jpeg');
    expect(result.single.bytes.length, 180 * 1024);
    expect(backend.pickedSource, ImageSourceKind.gallery);
    expect(backend.calls, hasLength(1));
    expect(backend.calls.first.side, 1568);
    expect(backend.calls.first.quality, 80);
  });

  test('oversized result re-compresses with smaller side + quality', () async {
    final backend = _FakeBackend()
      // First two passes blow the 1.5MB ceiling, the third lands under.
      ..sizes = [2000 * 1024, 1700 * 1024, 300 * 1024];
    final svc = ImagePickerService(backend);

    final result = await svc.pickFromCamera();
    expect(result!.bytes.length, 300 * 1024);
    expect(backend.calls.length, 3);
    // Side + quality shrink monotonically across passes.
    expect(backend.calls[1].side, lessThan(backend.calls[0].side));
    expect(backend.calls[1].quality, lessThan(backend.calls[0].quality));
    expect(backend.calls[2].side, lessThan(backend.calls[1].side));
  });

  test('gallery multi-select compresses every image in picker order', () async {
    final backend = _FakeBackend()
      ..galleryPaths = ['/tmp/first.jpg', '/tmp/second.jpg']
      ..sizes = [101, 202];
    final svc = ImagePickerService(backend);

    final result = await svc.pickFromGallery(limit: 2);

    expect(result.map((image) => image.bytes.length), [101, 202]);
    expect(backend.calls.map((call) => call.path), [
      '/tmp/first.jpg',
      '/tmp/second.jpg',
    ]);
    expect(backend.pickedLimit, 2);
  });

  test('one remaining slot uses the singular gallery adapter path', () async {
    final backend = _FakeBackend()
      ..path = '/tmp/final-slot.jpg'
      ..sizes = [321];
    final svc = ImagePickerService(backend);

    final result = await svc.pickFromGallery(limit: 1);

    expect(result, hasLength(1));
    expect(result.single.bytes, hasLength(321));
    expect(backend.pickedSource, ImageSourceKind.gallery);
    expect(
      backend.pickedLimit,
      isNull,
      reason: 'multi adapter rejects limit 1',
    );
    expect(backend.calls.single.path, '/tmp/final-slot.jpg');
  });

  test(
    'cancelled gallery pick returns an empty list and never compresses',
    () async {
      final backend = _FakeBackend()..galleryPaths = [];
      final svc = ImagePickerService(backend);
      expect(await svc.pickFromGallery(), isEmpty);
      expect(backend.calls, isEmpty);
    },
  );

  test('an image still over 1.5 MiB after retries is rejected', () async {
    final backend = _FakeBackend()..sizes = List.filled(4, 2000 * 1024);
    final svc = ImagePickerService(backend);

    await expectLater(
      svc.pickFromCamera(),
      throwsA(isA<ImageTooLargeException>()),
    );
    expect(backend.calls, hasLength(4));
  });

  test('denied camera permission propagates as a typed exception', () async {
    final backend = _FakeBackend()..denied = true;
    final svc = ImagePickerService(backend);
    expect(
      () => svc.pickFromCamera(),
      throwsA(isA<ImagePermissionDeniedException>()),
    );
  });
}
