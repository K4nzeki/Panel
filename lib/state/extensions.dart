import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/extension_covers.dart';
import '../services/extension_repo.dart';
import '../services/sources/apk_source.dart';
import 'providers.dart';

/// An extension app that's on the phone.
class InstalledExtension {
  const InstalledExtension(this.pkg, this.versionCode, this.versionName);
  final String pkg;
  final int versionCode;
  final String versionName;
}

class ExtensionStoreState {
  const ExtensionStoreState({
    this.repoUrls = const [],
    this.repos = const {},
    this.repoErrors = const {},
    this.installed = const {},
    this.downloading = const {},
    this.loading = false,
  });

  final List<String> repoUrls;
  final Map<String, ExtRepo> repos;
  final Map<String, String> repoErrors;
  final Map<String, InstalledExtension> installed;

  /// Package -> download progress (0–1, null while unknown).
  final Map<String, double?> downloading;
  final bool loading;

  /// Every extension from every repo; the first repo wins on duplicates.
  List<Extension> get extensions {
    final seen = <String>{};
    return [
      for (final url in repoUrls)
        for (final e in repos[url]?.extensions ?? const <Extension>[])
          if (seen.add(e.pkg)) e,
    ];
  }

  bool isInstalled(Extension e) => installed.containsKey(e.pkg);

  bool hasUpdate(Extension e) {
    final i = installed[e.pkg];
    return i != null && e.versionCode > i.versionCode;
  }

  ExtensionStoreState copyWith({
    List<String>? repoUrls,
    Map<String, ExtRepo>? repos,
    Map<String, String>? repoErrors,
    Map<String, InstalledExtension>? installed,
    Map<String, double?>? downloading,
    bool? loading,
  }) =>
      ExtensionStoreState(
        repoUrls: repoUrls ?? this.repoUrls,
        repos: repos ?? this.repos,
        repoErrors: repoErrors ?? this.repoErrors,
        installed: installed ?? this.installed,
        downloading: downloading ?? this.downloading,
        loading: loading ?? this.loading,
      );
}

/// Extension repos the user added, what they list, and which extensions
/// are installed. Installing downloads the APK and opens Android's
/// installer (extensions are separate apps, like in Mihon).
///
/// The last good copy of every repo is saved on the phone, so browsing the
/// store, the installed list and the reading sources all work offline; the
/// repos are re-downloaded when there's a connection.
class ExtensionStoreNotifier extends Notifier<ExtensionStoreState> {
  static const _reposKey = 'ext_repos_v1';
  static const _channel = MethodChannel('com.readlist.panel/updater');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  final _service = ExtensionRepoService();
  final _client = http.Client();
  AppLifecycleListener? _lifecycle;

  @override
  ExtensionStoreState build() {
    // Back from the installer / uninstaller: see what changed.
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onResume: () {
      unawaited(refreshInstalled());
    });
    ref.onDispose(() => _lifecycle?.dispose());
    unawaited(Future.microtask(_load));
    return const ExtensionStoreState(loading: true);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final urls = prefs.getStringList(_reposKey) ?? const <String>[];
    final cached = await _readCache();
    state = state.copyWith(repoUrls: urls, repos: {
      for (final u in urls)
        if (cached[u] case final r?) u: r,
    });
    // Installed apps are on the phone: show them before the network answers.
    await refreshInstalled();
    await refresh();
  }

  // ---- Offline copy of the repos ----

  static Future<File?> _cacheFile() async {
    if (kIsWeb) return null;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}ext_repos_v1.json');
  }

  static Future<Map<String, ExtRepo>> _readCache() async {
    try {
      final f = await _cacheFile();
      if (f == null || !await f.exists()) return const {};
      final j = jsonDecode(await f.readAsString());
      if (j is! List) return const {};
      return {
        for (final r in j)
          if (ExtRepo.fromJson(r) case final repo?) repo.url: repo,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _writeCache() async {
    try {
      final f = await _cacheFile();
      if (f == null) return;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode([
        for (final u in state.repoUrls)
          if (state.repos[u] case final r? when r.extensions.isNotEmpty)
            r.toJson(),
      ]));
      await tmp.rename(f.path);
    } catch (_) {}
  }

  Future<void> _saveUrls(List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_reposKey, urls);
  }

  /// Re-downloads every repo's list and re-reads what's installed.
  Future<void> refresh() async {
    state = state.copyWith(loading: true);
    final repos = <String, ExtRepo>{...state.repos};
    final errors = <String, String>{};
    await Future.wait([
      for (final url in state.repoUrls)
        _service.fetch(url).then((r) => repos[url] = r).catchError((Object e) {
          errors[url] = e.toString();
          return repos[url] ?? ExtRepo(url: url, name: url, extensions: const []);
        }),
    ]);
    state = state.copyWith(repos: repos, repoErrors: errors, loading: false);
    if (errors.length < state.repoUrls.length) unawaited(_writeCache());
    await refreshInstalled();
  }

  Future<void> refreshInstalled() async {
    if (!supported) return;
    try {
      final raw = await _channel.invokeListMethod<Map>('installedExtensions');
      final installed = {
        for (final m in raw ?? const <Map>[])
          '${m['package']}': InstalledExtension(
            '${m['package']}',
            (m['versionCode'] as num?)?.toInt() ?? 0,
            '${m['versionName'] ?? ''}',
          ),
      };
      state = state.copyWith(installed: installed);
      await _saveCoverSources();
    } catch (_) {
      // Older build without the native side: show nothing as installed.
    }
  }

  /// Hands the installed extensions' sites to the cover finder.
  Future<void> _saveCoverSources() async {
    // A repo that didn't load (offline) would look like "nothing installed"
    // and wipe the list; keep the last good one instead.
    if (state.repoErrors.isNotEmpty ||
        state.repoUrls.any((u) => !state.repos.containsKey(u))) {
      return;
    }
    final sources = [
      for (final e in state.extensions)
        if (state.installed.containsKey(e.pkg) && !e.isNsfw) ...e.sources,
    ];
    final before = (await ExtensionCoverFinder.load()).signature;
    await ExtensionCoverFinder.saveSources(sources);
    if (ExtensionCoverFinder(sources).signature != before) {
      // New sites to look on: try the titles still missing a cover.
      unawaited(ref.read(entriesProvider.notifier).fillMissingCovers());
    }
  }

  /// Checks the link really is a repo, then adds it. Returns the repo so the
  /// caller can show its name. Throws [ExtensionRepoException] with a
  /// friendly message otherwise.
  Future<ExtRepo> addRepo(String input) async {
    final url = ExtensionRepoService.normalizeUrl(input);
    if (url == null) {
      throw const ExtensionRepoException('Paste the full repo link.');
    }
    if (state.repoUrls.contains(url)) {
      throw const ExtensionRepoException('That repo is already added.');
    }
    final repo = await _service.fetch(url);
    final urls = [...state.repoUrls, url];
    await _saveUrls(urls);
    state = state.copyWith(
      repoUrls: urls,
      repos: {...state.repos, url: repo},
      repoErrors: {...state.repoErrors}..remove(url),
    );
    unawaited(_writeCache());
    await _saveCoverSources();
    return repo;
  }

  Future<void> removeRepo(String url) async {
    final urls = [...state.repoUrls]..remove(url);
    await _saveUrls(urls);
    state = state.copyWith(
      repoUrls: urls,
      repos: {...state.repos}..remove(url),
      repoErrors: {...state.repoErrors}..remove(url),
    );
    unawaited(_writeCache());
    await _saveCoverSources();
  }

  /// Downloads [e] and opens the installer. Returns false when Android
  /// first needs "install unknown apps" allowed (that setting is opened).
  Future<bool> install(Extension e) async {
    if (!supported) {
      throw const ExtensionRepoException(
          'Extensions can only be installed on Android.');
    }
    if (state.downloading.containsKey(e.pkg)) return true;
    void progress(double? p) =>
        state = state.copyWith(downloading: {...state.downloading, e.pkg: p});
    progress(null);
    try {
      final dir = await _channel.invokeMethod<String>('extensionDir');
      final file = File('$dir/${e.pkg}.apk');
      final res = await _client.send(http.Request('GET', Uri.parse(e.apkUrl)));
      if (res.statusCode != 200) {
        throw ExtensionRepoException('Download failed (${res.statusCode}).');
      }
      final total = res.contentLength;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          progress(total != null && total > 0 ? received / total : null);
        }
      } finally {
        await sink.close();
      }
      if (total != null && total > 0 && received < total) {
        throw const ExtensionRepoException('Download was cut off. Try again.');
      }
      final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
      if (!allowed) {
        await _channel.invokeMethod('openInstallSettings');
        return false;
      }
      await _channel.invokeMethod('installApk', {'path': file.path});
      return true;
    } on ExtensionRepoException {
      rethrow;
    } on SocketException {
      throw const ExtensionRepoException(
          "Couldn't download it. Check your connection.");
    } finally {
      state = state.copyWith(
          downloading: {...state.downloading}..remove(e.pkg));
    }
  }

  Future<void> uninstall(String pkg) async {
    if (!supported) return;
    await _channel.invokeMethod('uninstallPackage', {'package': pkg});
  }
}

final extensionStoreProvider =
    NotifierProvider<ExtensionStoreNotifier, ExtensionStoreState>(
        ExtensionStoreNotifier.new);

// ---------------------------------------------------------------------------
// Extensions run natively (Android)
// ---------------------------------------------------------------------------

/// The installed extensions Panel runs itself, and the ones waiting to be
/// trusted. Reloads when apps are installed/removed or your repos change
/// (a repo's signing key makes its extensions trusted).
class ApkExtensionsNotifier extends Notifier<ApkExtensions> {
  int _gen = 0;
  ApkExtensions _last = const ApkExtensions();

  @override
  ApkExtensions build() {
    if (!ApkBridge.supported) return const ApkExtensions();
    final keys = ref.watch(extensionStoreProvider.select(_repoKeys));
    ref.watch(extensionStoreProvider.select((s) => s.installed));
    final gen = ++_gen;
    unawaited(Future.microtask(() => _load(gen, keys)));
    return _last;
  }

  /// Signing keys of every repo, or null while the repos aren't known yet
  /// (then the keys saved on the Android side are used as they are).
  static String? _repoKeys(ExtensionStoreState s) {
    final known = (!s.loading || s.repoUrls.isNotEmpty) &&
        s.repoUrls.every(s.repos.containsKey);
    if (!known) return null;
    final keys = <String>{
      for (final r in s.repos.values)
        if (r.fingerprint case final f? when f.trim().isNotEmpty) f.trim(),
    }.toList()
      ..sort();
    return keys.join(',');
  }

  Future<void> _load(int gen, String? keys, {bool reload = false}) async {
    try {
      if (keys != null) {
        await ApkBridge.setTrustedKeys(keys.split(',').where((k) => k.isNotEmpty));
      }
      final next = await ApkBridge.load(reload: reload);
      if (!ref.mounted || gen != _gen) return;
      _last = next;
      state = next;
    } catch (_) {
      // Older build without the native side, or a broken extension list:
      // keep what we had; website sources still work. Marked as loaded so
      // sources don't say "still loading" forever.
      if (!ref.mounted || gen != _gen || _last.loaded) return;
      _last = ApkExtensions(
          sources: _last.sources, errors: _last.errors, loaded: true);
      state = _last;
    }
  }

  /// Loads everything again (after trusting, or "reload extensions").
  Future<void> refresh({bool reload = false}) =>
      _load(++_gen, _repoKeys(ref.read(extensionStoreProvider)), reload: reload);

  Future<void> trust(String pkg, String signature) async {
    await ApkBridge.trust(pkg, signature);
    await refresh();
  }

  Future<void> untrust(String pkg) async {
    await ApkBridge.untrust(pkg);
    await refresh();
  }
}

final apkExtensionsProvider =
    NotifierProvider<ApkExtensionsNotifier, ApkExtensions>(
        ApkExtensionsNotifier.new);
