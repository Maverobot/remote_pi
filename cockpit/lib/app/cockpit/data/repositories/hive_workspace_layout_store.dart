import 'dart:convert';

import 'package:cockpit/app/cockpit/domain/contracts/workspace_layout_store.dart';
import 'package:hive/hive.dart';

/// Persiste o documento de layout numa Box do Hive, **uma String JSON por
/// `projectId`**. Serializar pra String evita a dor dos `Map<dynamic, dynamic>`
/// aninhados que o Hive devolve — voltamos sempre um `Map<String, dynamic>` limpo.
class HiveWorkspaceLayoutStore implements WorkspaceLayoutStore {
  HiveWorkspaceLayoutStore(this._box);

  final Box<dynamic> _box;

  static const String boxName = 'layouts';

  @override
  Future<Map<String, dynamic>?> load(String projectId) async {
    final raw = _box.get(projectId);
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null; // documento corrompido → trata como inexistente
    }
  }

  @override
  Future<void> save(String projectId, Map<String, dynamic> document) =>
      _box.put(projectId, jsonEncode(document));

  @override
  Future<void> remove(String projectId) => _box.delete(projectId);
}
