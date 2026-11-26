/// One chapter on a reading source.
class ChapterInfo {
  const ChapterInfo({
    required this.key,
    required this.name,
    this.number,
    this.scanlator,
    this.uploadedAt,
    this.url,
  });

  /// The source's own id for it: a MangaDex chapter id, or the chapter's
  /// page URL on a website source.
  final String key;

  /// What the source calls it, e.g. "Chapter 12: The Gate".
  final String name;

  /// Chapter number when the source gives one (12.5 for extras).
  final double? number;

  /// Who translated it (MangaDex groups). Website sources use the site name.
  final String? scanlator;
  final DateTime? uploadedAt;

  /// Web page for "open in browser".
  final String? url;

  String get scanlatorLabel =>
      (scanlator == null || scanlator!.trim().isEmpty) ? 'Unknown' : scanlator!;

  /// "12", "12.5" — or the name when there's no number.
  String get shortLabel {
    final n = number;
    if (n == null) return name;
    return n == n.roundToDouble() ? 'Ch ${n.toInt()}' : 'Ch $n';
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'number': number,
        'scanlator': scanlator,
        'uploaded_at': uploadedAt?.millisecondsSinceEpoch,
        'url': url,
      };

  static ChapterInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['key'], name = j['name'];
    if (key is! String || name is! String) return null;
    final up = j['uploaded_at'];
    return ChapterInfo(
      key: key,
      name: name,
      number: (j['number'] as num?)?.toDouble(),
      scanlator: j['scanlator'] as String?,
      uploadedAt: up is int ? DateTime.fromMillisecondsSinceEpoch(up) : null,
      url: j['url'] as String?,
    );
  }
}

/// A series found on a reading source.
class SourceSeries {
  const SourceSeries({
    required this.key,
    required this.title,
    this.coverUrl,
    this.url,
    this.subtitle,
  });

  /// MangaDex manga id, or the series page URL on a website source.
  final String key;
  final String title;
  final String? coverUrl;
  final String? url;
  final String? subtitle;
}

/// Where a title in your list is read from, which translations you want,
/// and where you stopped. Saved on the phone per title.
class ReadingLink {
  const ReadingLink({
    required this.sourceId,
    required this.sourceName,
    required this.seriesKey,
    required this.seriesTitle,
    this.sourceLang = '',
    this.sourceBaseUrl,
    this.seriesUrl,
    this.scanlators = const {},
    this.lastChapterKey,
    this.lastChapterNumber,
    this.lastScanlator,
    this.lastPage = 0,
    this.lastPageOffset = 0,
    this.lastPageCount,
    this.lastFinished = false,
    this.lastReadAt,
  });

  final String sourceId;
  final String sourceName;
  final String sourceLang;

  /// Website sources only: the site, so the source works even when its
  /// extension isn't installed (or the repo can't be reached) any more.
  final String? sourceBaseUrl;

  final String seriesKey;
  final String seriesTitle;
  final String? seriesUrl;

  /// Translations to show. Empty = all of them.
  final Set<String> scanlators;

  // ---- Where you stopped ----
  final String? lastChapterKey;
  final double? lastChapterNumber;
  final String? lastScanlator;
  /// 0-based page you were on.
  final int lastPage;

  /// How far down [lastPage] you were, 0..1 (webtoon strips are one tall
  /// "page", so the page number alone can be a long way off).
  final double lastPageOffset;
  final int? lastPageCount;

  /// You reached the end of [lastChapterKey]; Resume goes to the next one.
  final bool lastFinished;
  final DateTime? lastReadAt;

  bool get hasProgress => lastChapterKey != null || lastChapterNumber != null;

  ReadingLink copyWith({
    Set<String>? scanlators,
    String? lastChapterKey,
    double? lastChapterNumber,
    String? lastScanlator,
    int? lastPage,
    double? lastPageOffset,
    int? lastPageCount,
    bool? lastFinished,
    DateTime? lastReadAt,
  }) =>
      ReadingLink(
        sourceId: sourceId,
        sourceName: sourceName,
        sourceLang: sourceLang,
        sourceBaseUrl: sourceBaseUrl,
        seriesKey: seriesKey,
        seriesTitle: seriesTitle,
        seriesUrl: seriesUrl,
        scanlators: scanlators ?? this.scanlators,
        lastChapterKey: lastChapterKey ?? this.lastChapterKey,
        lastChapterNumber: lastChapterNumber ?? this.lastChapterNumber,
        lastScanlator: lastScanlator ?? this.lastScanlator,
        lastPage: lastPage ?? this.lastPage,
        lastPageOffset: lastPageOffset ?? this.lastPageOffset,
        lastPageCount: lastPageCount ?? this.lastPageCount,
        lastFinished: lastFinished ?? this.lastFinished,
        lastReadAt: lastReadAt ?? this.lastReadAt,
      );

  /// Same title on another source: keeps the chapter number you were on
  /// (chapter ids differ between sources) and drops the rest.
  ReadingLink movedTo({
    required String sourceId,
    required String sourceName,
    required String sourceLang,
    required String? sourceBaseUrl,
    required SourceSeries series,
  }) =>
      ReadingLink(
        sourceId: sourceId,
        sourceName: sourceName,
        sourceLang: sourceLang,
        sourceBaseUrl: sourceBaseUrl,
        seriesKey: series.key,
        seriesTitle: series.title,
        seriesUrl: series.url,
        lastChapterNumber: lastChapterNumber,
        lastFinished: lastFinished,
        lastReadAt: lastReadAt,
      );

  Map<String, dynamic> toJson() => {
        'source_id': sourceId,
        'source_name': sourceName,
        'source_lang': sourceLang,
        'source_base_url': sourceBaseUrl,
        'series_key': seriesKey,
        'series_title': seriesTitle,
        'series_url': seriesUrl,
        'scanlators': scanlators.toList(),
        'last_chapter_key': lastChapterKey,
        'last_chapter_number': lastChapterNumber,
        'last_scanlator': lastScanlator,
        'last_page': lastPage,
        'last_page_offset': lastPageOffset,
        'last_page_count': lastPageCount,
        'last_finished': lastFinished,
        'last_read_at': lastReadAt?.millisecondsSinceEpoch,
      };

  static ReadingLink? fromJson(Object? j) {
    if (j is! Map) return null;
    final sourceId = j['source_id'], seriesKey = j['series_key'];
    if (sourceId is! String || seriesKey is! String) return null;
    final at = j['last_read_at'];
    return ReadingLink(
      sourceId: sourceId,
      sourceName: '${j['source_name'] ?? sourceId}',
      sourceLang: '${j['source_lang'] ?? ''}',
      sourceBaseUrl: j['source_base_url'] as String?,
      seriesKey: seriesKey,
      seriesTitle: '${j['series_title'] ?? ''}',
      seriesUrl: j['series_url'] as String?,
      scanlators: {
        for (final s in (j['scanlators'] as List?) ?? const [])
          if (s is String) s,
      },
      lastChapterKey: j['last_chapter_key'] as String?,
      lastChapterNumber: (j['last_chapter_number'] as num?)?.toDouble(),
      lastScanlator: j['last_scanlator'] as String?,
      lastPage: (j['last_page'] as num?)?.toInt() ?? 0,
      lastPageOffset: ((j['last_page_offset'] as num?)?.toDouble() ?? 0)
          .clamp(0.0, 1.0)
          .toDouble(),
      lastPageCount: (j['last_page_count'] as num?)?.toInt(),
      lastFinished: j['last_finished'] == true,
      lastReadAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

/// Finds a chapter number in names like "Chapter 12.5", "Ch. 7 - Title",
/// "Episode 40" or just "12".
double? parseChapterNumber(String name) {
  final s = name.toLowerCase();
  final labelled = RegExp(
          r'(?:chapter|chap|ch|episode|ep|#)\.?\s*(\d+(?:[.,]\d+)?)')
      .firstMatch(s);
  final m = labelled ?? RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(s);
  if (m == null) return null;
  return double.tryParse(m.group(1)!.replaceAll(',', '.'));
}

/// The chapters to show for the chosen translations.
List<ChapterInfo> filterByScanlator(
    List<ChapterInfo> chapters, Set<String> scanlators) {
  if (scanlators.isEmpty) return chapters;
  return [
    for (final c in chapters)
      if (scanlators.contains(c.scanlatorLabel)) c,
  ];
}

/// Oldest-first reading order with one release per chapter number: when
/// several groups translated the same chapter, the one by [preferred] (the
/// group you were last reading) wins, otherwise the first listed.
List<ChapterInfo> readingOrder(List<ChapterInfo> chapters,
    {String? preferred}) {
  if (chapters.isEmpty) return const [];
  // Sources list newest first; flip to oldest first, then sort by number
  // where there is one (stable, so unnumbered extras keep their place).
  final ordered = chapters.reversed.toList();
  final numbered = ordered.where((c) => c.number != null).length;
  if (numbered >= ordered.length / 2) {
    final pos = {for (var i = 0; i < ordered.length; i++) ordered[i].key: i};
    ordered.sort((a, b) {
      final an = a.number, bn = b.number;
      if (an != null && bn != null && an != bn) return an.compareTo(bn);
      return pos[a.key]!.compareTo(pos[b.key]!);
    });
  }
  final out = <ChapterInfo>[];
  final byNumber = <double, int>{};
  for (final c in ordered) {
    final n = c.number;
    if (n == null) {
      out.add(c);
      continue;
    }
    final at = byNumber[n];
    if (at == null) {
      byNumber[n] = out.length;
      out.add(c);
    } else if (preferred != null &&
        c.scanlatorLabel == preferred &&
        out[at].scanlatorLabel != preferred) {
      out[at] = c;
    }
  }
  return out;
}
