import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Checks the GitHub repo's latest release and installs its APK.
///
/// To ship an update: bump `version:` in pubspec.yaml, build the APK
/// (`flutter build apk --release`), then create a GitHub release tagged
/// with that version (e.g. `v1.7.0`) and attach the .apk file.
class Updater {
  Updater({http.Client? client}) : _client = client ?? http.Client();

  static const repo = 'K4nzeki/Panel';
  static const releasesPage = 'https://github.com/$repo/releases/latest';
  static const _channel = MethodChannel('com.readlist.panel/updater');

  final http.Client _client;

  /// In-app install only works on Android.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// The installed version, e.g. "1.7.0".
  Future<String> currentVersion() async =>
      (await _channel.invokeMethod<String>('appVersion')) ?? '0.0.0';

  /// The newest release if it's newer than this install, otherwise null.
  Future<AppRelease?> checkForUpdate() async {
    final res = await _client.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: const {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null; // no releases yet
    if (res.statusCode != 200) {
      throw UpdateException(res.statusCode == 403
          ? 'GitHub is limiting requests. Try again later.'
          : "Couldn't check for updates (${res.statusCode}).");
    }
    final release = AppRelease.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
    final current = await currentVersion();
    return isNewer(release.version, current) ? release : null;
  }

  /// Downloads the APK, reporting progress from 0 to 1 (null if the size
  /// is unknown). Returns the file path.
  Future<String> download(AppRelease release,
      {void Function(double? progress)? onProgress}) async {
    final url = release.apkUrl;
    if (url == null) {
      throw const UpdateException('This release has no APK attached.');
    }
    final dir = await _channel.invokeMethod<String>('updateDir');
    final file = File('$dir/Panel-${release.version}.apk');
    // Remove older downloads.
    for (final f in Directory(dir!).listSync()) {
      if (f is File && f.path != file.path) f.deleteSync();
    }

    final req = http.Request('GET', Uri.parse(url));
    final res = await _client.send(req);
    if (res.statusCode != 200) {
      throw UpdateException('Download failed (${res.statusCode}).');
    }
    final total = res.contentLength ?? release.apkSize;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total != null && total > 0 ? received / total : null);
      }
    } finally {
      await sink.close();
    }
    if (total != null && total > 0 && received < total) {
      throw const UpdateException('Download was cut off. Try again.');
    }
    return file.path;
  }

  /// Opens Android's installer. If "install unknown apps" isn't allowed
  /// yet, opens that setting instead and returns false.
  Future<bool> install(String path) async {
    final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
    if (!allowed) {
      await _channel.invokeMethod('openInstallSettings');
      return false;
    }
    await _channel.invokeMethod('installApk', {'path': path});
    return true;
  }
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.name,
    required this.notes,
    this.apkUrl,
    this.apkSize,
  });

  final String version;
  final String name;
  final String notes;
  final String? apkUrl;
  final int? apkSize;

  factory AppRelease.fromJson(Map<String, dynamic> j) {
    final tag = (j['tag_name'] as String? ?? '').trim();
    final assets = ((j['assets'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'))
        .toList();
    // Prefer a universal APK; fall back to the 64-bit ARM one most phones use.
    Map<String, dynamic>? pick;
    for (final a in assets) {
      final n = (a['name'] as String).toLowerCase();
      final isSplit =
          n.contains('armeabi') || n.contains('arm64') || n.contains('x86');
      if (!isSplit) {
        pick = a;
        break;
      }
      if (pick == null && n.contains('arm64')) pick = a;
    }
    pick ??= assets.isEmpty ? null : assets.first;
    return AppRelease(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? j['name'] as String
          : tag,
      notes: (j['body'] as String? ?? '').trim(),
      apkUrl: pick?['browser_download_url'] as String?,
      apkSize: (pick?['size'] as num?)?.toInt(),
    );
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// "1.10.0" > "1.9.2"; ignores a leading "v" and anything after "+" / "-".
bool isNewer(String candidate, String current) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[+\-]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
