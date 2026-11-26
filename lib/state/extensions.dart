import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/extension_covers.dart';
import '../services/extension_repo.dart';
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
    state = state.copyWith(repoUrls: prefs.getStringList(_reposKey) ?? const []);
    await refresh();
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
