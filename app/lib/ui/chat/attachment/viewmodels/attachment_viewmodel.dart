import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Drives the composer's ordered image attachment collection.
class AttachmentViewModel extends ViewModel<AttachmentState> {
  AttachmentViewModel(this._picker, this._actions)
    : super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
  }

  static const int maxImages = 10;

  final IImagePickerService _picker;
  final IActionsRepository _actions;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed / image cap).
  Stream<AttachHint> get hints => _hints.stream;

  bool get hasImage => state.images.isNotEmpty;
  int get imageCount => state.images.length;
  bool get canAddImages =>
      state is! AttachmentPicking && imageCount < maxImages;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(() async {
    final image = await _picker.pickFromCamera();
    return image == null ? const [] : [image];
  });

  Future<void> pickFromGallery() {
    final remaining = maxImages - imageCount;
    return _pick(() => _picker.pickFromGallery(limit: remaining));
  }

  Future<void> _pick(Future<List<PickedImage>> Function() pick) async {
    if (state is AttachmentPicking) return;
    final existing = state.images;
    if (existing.length >= maxImages) {
      _emitHint(AttachHint.imageLimitReached);
      return;
    }

    emit(
      AttachmentPicking(
        images: existing,
        visionSupported: state.visionSupported,
      ),
    );
    try {
      final picked = await pick();
      final remaining = maxImages - existing.length;
      final additions = picked.take(remaining).toList(growable: false);
      final combined = [...existing, ...additions];
      _emitImages(combined, state.visionSupported);
      if (combined.length >= maxImages || picked.length > additions.length) {
        _emitHint(AttachHint.imageLimitReached);
      }
    } on ImagePermissionDeniedException {
      _emitImages(existing, state.visionSupported);
      _emitHint(AttachHint.cameraPermissionDenied);
    } catch (_) {
      _emitImages(existing, state.visionSupported);
      _emitHint(AttachHint.pickFailed);
    }
  }

  /// Remove one preview without disturbing the order of remaining images.
  void removeImageAt(int index) {
    if (state is AttachmentPicking) return;
    final images = state.images;
    if (index < 0 || index >= images.length) return;
    final remaining = [
      for (var current = 0; current < images.length; current++)
        if (current != index) images[current],
    ];
    _emitImages(remaining, state.visionSupported);
  }

  /// Capture every attached image for dispatch and clear the composer in one
  /// state transition. Returns an empty list when nothing is attached.
  List<MessageImage> takeImagesForSend() {
    if (state is AttachmentPicking) return const [];
    final attached = state.images;
    if (attached.isEmpty) return const [];
    final images = List<MessageImage>.unmodifiable(
      attached.map(
        (image) =>
            MessageImage(data: base64Encode(image.bytes), mime: image.mime),
      ),
    );
    emit(AttachmentEmpty(visionSupported: state.visionSupported));
    return images;
  }

  void _emitImages(List<PickedImage> images, bool? visionSupported) {
    emit(
      images.isEmpty
          ? AttachmentEmpty(visionSupported: visionSupported)
          : AttachmentAttached(
              images: images,
              visionSupported: visionSupported,
            ),
    );
  }

  void _emitHint(AttachHint hint) {
    if (!_hints.isClosed) _hints.add(hint);
  }

  // ---------------------------------------------------------------------------
  // Vision tracking
  // ---------------------------------------------------------------------------

  Future<void> _refreshVision() async {
    if (_resolvingVision) return;
    _resolvingVision = true;
    try {
      final catalogue = await _actions.listModels();
      _setVision(_resolveVision(catalogue));
    } catch (_) {
      // Offline / no catalogue yet → leave vision unknown (don't gate).
    } finally {
      _resolvingVision = false;
    }
  }

  bool? _resolveVision(ModelsCatalogue catalogue) {
    final current = catalogue.current;
    if (current != null) return current.vision;
    final name = _actions.activeRoomMeta.model;
    if (name != null) {
      for (final model in catalogue.models) {
        if (model.name == name) return model.vision;
      }
    }
    return null;
  }

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentPicking(:final images) => AttachmentPicking(
        images: images,
        visionSupported: vision,
      ),
      AttachmentAttached(:final images) => AttachmentAttached(
        images: images,
        visionSupported: vision,
      ),
    });
  }

  @override
  void dispose() {
    _metaSub?.cancel();
    _hints.close();
    super.dispose();
  }
}
