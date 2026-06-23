import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/folder_lister.dart';

/// Lista subpastas via `dart:io`, ignorando ocultas (`.git`, `.dart_tool`…).
class FolderListerImpl implements FolderLister {
  const FolderListerImpl();

  @override
  Future<List<String>> subfolders(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) return const <String>[];
    final names = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      names.add(name);
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }
}
