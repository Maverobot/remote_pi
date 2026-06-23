import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:hive/hive.dart';

/// Persiste a versão de atualização dispensada numa chave própria da Box de
/// settings (reusa a box, sem TypeAdapter — só uma String).
class HiveDismissedUpdateStore implements DismissedUpdateStore {
  HiveDismissedUpdateStore(this._box);

  final Box<dynamic> _box;

  static const String _key = 'dismissed_update_version';

  @override
  String? dismissedVersion() {
    final raw = _box.get(_key);
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  @override
  Future<void> dismiss(String version) => _box.put(_key, version);
}
