// Plan/30 — AttachmentViewModel: pick / remove / take + vision gating,
// against fake picker + actions repositories.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements IImagePickerService {
  PickedImage? nextCamera = PickedImage(
    bytes: Uint8List.fromList([1, 2, 3]),
    mime: 'image/jpeg',
  );
  List<PickedImage> nextGallery = [
    PickedImage(bytes: Uint8List.fromList([1, 2, 3]), mime: 'image/jpeg'),
  ];
  bool denyCamera = false;
  bool fail = false;
  int? galleryLimit;
  int cameraCalls = 0;
  int galleryCalls = 0;
  Completer<List<PickedImage>>? delayedGallery;

  @override
  Future<PickedImage?> pickFromCamera() async {
    cameraCalls++;
    if (denyCamera) throw const ImagePermissionDeniedException();
    if (fail) throw Exception('boom');
    return nextCamera;
  }

  @override
  Future<List<PickedImage>> pickFromGallery({int limit = 10}) async {
    galleryCalls++;
    galleryLimit = limit;
    if (fail) throw Exception('boom');
    final delayed = delayedGallery;
    if (delayed != null) return delayed.future;
    return nextGallery.take(limit).toList();
  }
}

class _FakeActions implements IActionsRepository {
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  ActiveRoomMeta meta = const ActiveRoomMeta();
  final _metaCtrl = StreamController<ActiveRoomMeta>.broadcast();
  bool offline = false;

  void pushMeta(ActiveRoomMeta m) {
    meta = m;
    _metaCtrl.add(m);
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    if (offline) throw const ActionFailure('offline');
    return catalogue;
  }

  @override
  ActiveRoomMeta get activeRoomMeta => meta;

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream => _metaCtrl.stream;

  @override
  void dispose() => _metaCtrl.close();

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

WireModel _model({required bool vision, String name = 'M'}) => WireModel(
  id: 'id-$name',
  name: name,
  provider: 'p',
  reasoning: false,
  contextWindow: 1,
  vision: vision,
);

void main() {
  test(
    'gallery and camera append in stable order; indexed removal preserves the rest',
    () async {
      final picker = _FakePicker()
        ..nextGallery = [
          PickedImage(bytes: Uint8List.fromList([1]), mime: 'image/jpeg'),
          PickedImage(bytes: Uint8List.fromList([2]), mime: 'image/jpeg'),
        ]
        ..nextCamera = PickedImage(
          bytes: Uint8List.fromList([3]),
          mime: 'image/jpeg',
        );
      final vm = AttachmentViewModel(picker, _FakeActions());

      await vm.pickFromGallery();
      picker.nextGallery = [
        PickedImage(bytes: Uint8List.fromList([3]), mime: 'image/jpeg'),
      ];
      picker.nextCamera = PickedImage(
        bytes: Uint8List.fromList([4]),
        mime: 'image/jpeg',
      );
      await vm.pickFromGallery();
      await vm.pickFromCamera();

      final attached = vm.state as AttachmentAttached;
      expect(attached.images.map((image) => image.bytes.single), [1, 2, 3, 4]);
      vm.removeImageAt(1);
      expect(
        (vm.state as AttachmentAttached).images.map(
          (image) => image.bytes.single,
        ),
        [1, 3, 4],
      );
      vm.dispose();
    },
  );

  test(
    'takeImagesForSend returns every image as base64 and resets atomically',
    () async {
      final picker = _FakePicker()
        ..nextGallery = [
          PickedImage(bytes: Uint8List.fromList([10]), mime: 'image/jpeg'),
          PickedImage(bytes: Uint8List.fromList([20]), mime: 'image/jpeg'),
        ];
      final vm = AttachmentViewModel(picker, _FakeActions());
      await vm.pickFromGallery();

      final images = vm.takeImagesForSend();
      expect(images.map((image) => base64Decode(image.data).single), [10, 20]);
      expect(vm.state, isA<AttachmentEmpty>());
      expect(vm.takeImagesForSend(), isEmpty);
      vm.dispose();
    },
  );

  test(
    'the tenth image reaches the cap, emits feedback, and blocks additions',
    () async {
      final picker = _FakePicker()
        ..nextGallery = List.generate(
          AttachmentViewModel.maxImages,
          (index) => PickedImage(
            bytes: Uint8List.fromList([index]),
            mime: 'image/jpeg',
          ),
        );
      final vm = AttachmentViewModel(picker, _FakeActions());
      final hints = <AttachHint>[];
      final sub = vm.hints.listen(hints.add);

      await vm.pickFromGallery();
      await Future<void>.delayed(Duration.zero);
      expect(vm.imageCount, AttachmentViewModel.maxImages);
      expect(vm.canAddImages, isFalse);
      expect(hints, contains(AttachHint.imageLimitReached));

      await vm.pickFromCamera();
      expect(vm.imageCount, AttachmentViewModel.maxImages);
      expect(picker.galleryLimit, AttachmentViewModel.maxImages);
      await sub.cancel();
      vm.dispose();
    },
  );

  test(
    'an in-flight pick blocks removal, send capture, and overlapping picks',
    () async {
      final picker = _FakePicker();
      final vm = AttachmentViewModel(picker, _FakeActions());
      await vm.pickFromGallery();
      final delayed = Completer<List<PickedImage>>();
      picker.delayedGallery = delayed;

      final inFlight = vm.pickFromGallery();
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<AttachmentPicking>());

      vm.removeImageAt(0);
      expect(vm.imageCount, 1, reason: 'existing preview cannot mutate');
      expect(
        vm.takeImagesForSend(),
        isEmpty,
        reason: 'send capture is blocked',
      );
      await vm.pickFromCamera();
      expect(picker.cameraCalls, 0, reason: 'overlapping picker is blocked');

      delayed.complete([
        PickedImage(bytes: Uint8List.fromList([4]), mime: 'image/jpeg'),
      ]);
      await inFlight;

      expect(
        (vm.state as AttachmentAttached).images.map((image) => image.bytes),
        [
          [1, 2, 3],
          [4],
        ],
      );
      expect(picker.galleryCalls, 2);
      vm.dispose();
    },
  );

  test('a failed addition preserves images already attached', () async {
    final picker = _FakePicker();
    final vm = AttachmentViewModel(picker, _FakeActions());
    await vm.pickFromGallery();
    picker.fail = true;

    await vm.pickFromCamera();

    expect(vm.imageCount, 1);
    expect(vm.state, isA<AttachmentAttached>());
    vm.dispose();
  });

  test('denied camera permission emits a hint and stays empty', () async {
    final picker = _FakePicker()..denyCamera = true;
    final vm = AttachmentViewModel(picker, _FakeActions());
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFromCamera();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.cameraPermissionDenied]);
    await sub.cancel();
    vm.dispose();
  });

  test('vision=false from catalogue blocks the attach affordance', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: false)],
        current: _model(vision: false),
      );
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero); // let init resolve vision

    expect(vm.state.visionSupported, isFalse);
    expect(vm.state.attachBlockedByVision, isTrue);
    vm.dispose();
  });

  test('vision=true does not block', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isTrue);
    expect(vm.state.attachBlockedByVision, isFalse);
    vm.dispose();
  });

  test('offline catalogue leaves vision unknown (does not block)', () async {
    final actions = _FakeActions()..offline = true;
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isNull);
    expect(vm.state.attachBlockedByVision, isFalse);
    vm.dispose();
  });

  test('a model change re-resolves vision', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), actions);
    await Future<void>.delayed(Duration.zero);
    expect(vm.state.visionSupported, isTrue);

    // Pi switched to a text-only model.
    actions.catalogue = ModelsCatalogue(
      models: [_model(vision: false, name: 'TextOnly')],
      current: _model(vision: false, name: 'TextOnly'),
    );
    actions.pushMeta(const ActiveRoomMeta(model: 'TextOnly'));
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isFalse);
    vm.dispose();
  });
}
