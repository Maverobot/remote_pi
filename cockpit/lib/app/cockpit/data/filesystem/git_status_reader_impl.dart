import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/git_status_reader.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_info.dart';

/// Lê o estado git rodando o binário `git`. Como o app macOS **não herda o PATH
/// do shell**, resolvemos o caminho do `git` por candidatos conhecidos (cacheado).
class GitStatusReaderImpl implements GitStatusReader {
  GitStatusReaderImpl();

  String? _git; // caminho do binário, resolvido uma vez

  static const List<String> _candidates = <String>[
    '/usr/bin/git',
    '/opt/homebrew/bin/git',
    '/usr/local/bin/git',
  ];

  Future<String> _resolveGit() async {
    final cached = _git;
    if (cached != null) return cached;
    for (final candidate in _candidates) {
      if (await File(candidate).exists()) return _git = candidate;
    }
    return _git = 'git'; // último recurso: PATH
  }

  @override
  Future<GitInfo?> read(String path) async {
    try {
      final git = await _resolveGit();

      // Branch atual — também serve de teste "é repo git?" (exit != 0 → não é).
      final branchRes = await Process.run(git, [
        '-C',
        path,
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ]);
      if (branchRes.exitCode != 0) return null;
      var branch = (branchRes.stdout as String).trim();
      if (branch.isEmpty) return null;
      if (branch == 'HEAD') {
        // detached HEAD → mostra o short SHA no lugar do nome do branch.
        final shaRes = await Process.run(git, [
          '-C',
          path,
          'rev-parse',
          '--short',
          'HEAD',
        ]);
        branch = shaRes.exitCode == 0
            ? (shaRes.stdout as String).trim()
            : 'HEAD';
      }

      // Arquivos sujos (modificados + staged + untracked).
      final statusRes = await Process.run(git, [
        '-C',
        path,
        'status',
        '--porcelain',
      ]);
      final dirty = statusRes.exitCode == 0
          ? (statusRes.stdout as String)
                .split('\n')
                .where((l) => l.trim().isNotEmpty)
                .length
          : 0;

      return GitInfo(branch: branch, dirtyCount: dirty);
    } catch (_) {
      return null; // git ausente / pasta inacessível
    }
  }
}
