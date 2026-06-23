import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/contracts/url_opener.dart';
import 'package:cockpit/app/cockpit/domain/entities/update_info.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/semver.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/update_target.dart';
import 'package:flutter/foundation.dart';

/// Aviso de atualização in-app (plano 43, passo 7). No [check] (chamado no
/// boot) consulta o manifest; se houver versão **maior** que a atual e que **não
/// foi dispensada**, expõe [available] (a UI mostra o mini card). Tudo
/// best-effort: falhas são silenciosas.
class UpdateViewModel extends ChangeNotifier {
  UpdateViewModel(
    this._checker,
    this._dismissed,
    this._opener,
    this._target, {
    this.fallbackUrl = _kFallbackUrl,
  });

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final UrlOpener _opener;
  final UpdateTarget _target;

  /// Versão do app rodando (de package_info, resolvida no boot).
  String get currentVersion => _target.version;

  /// Plataforma/arch correntes pra escolher o artefato (resolvidos no boot).
  String get platform => _target.platform;
  String get format => _target.format;
  String get arch => _target.arch;

  /// Página de download do site — fallback quando não há artefato da plataforma.
  final String fallbackUrl;

  static const String _kFallbackUrl =
      'https://remote-pi.jacobmoura.work/download';

  UpdateInfo? _available;
  bool _disposed = false;

  /// A atualização a anunciar, ou `null` se não há nada (atual/menor/dispensada/
  /// indisponível).
  UpdateInfo? get available => _available;

  /// Consulta o manifest e decide se o card deve aparecer. Silencioso em falha.
  Future<void> check() async {
    final latest = await _checker.fetchLatest();
    if (latest == null) return; // sem rede/manifest/inválido → nada.
    if (!isNewerVersion(latest.version, currentVersion)) return; // igual/menor.
    if (_dismissed.dismissedVersion() == latest.version) return; // dispensada.
    _available = latest;
    _safeNotify();
  }

  /// Fecha o card e persiste a versão como dispensada — não reaparece pra ela.
  Future<void> dismiss() async {
    final v = _available?.version;
    _available = null;
    _safeNotify();
    if (v != null) await _dismissed.dismiss(v);
  }

  /// Baixa o artefato da plataforma corrente (abre a URL no navegador). Sem
  /// artefato compatível → abre a página de download do site.
  Future<void> download() async {
    final info = _available;
    if (info == null) return;
    final artifact = info.artifactFor(
      platform: platform,
      format: format,
      arch: arch,
    );
    await _opener.open(artifact?.url ?? fallbackUrl);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
