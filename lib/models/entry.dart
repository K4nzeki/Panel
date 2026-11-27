/// Kinds of titles the app tracks. Saved as their [label].
enum EntryType {
  manga('Manga'),
  manhwa('Manhwa'),
  manhua('Manhua'),
  comic('Comic');

  const EntryType(this.label);
  final String label;

  static EntryType? tryParse(String? raw) {
    if (raw == null) return null;
    final v = raw.trim().toLowerCase();
    for (final t in EntryType.values) {
      if (t.label.toLowerCase() == v) return t;
    }
    return null;
  }

  static EntryType parse(String? raw) => tryParse(raw) ?? EntryType.manga;
}

/// Reading status. Saved as their [label].
enum EntryStatus {
  toRead('To Read'),
  reading('Reading'),
  finished('Finished'),
  dropped('Dropped'),
  cancelled('Cancelled');

  const EntryStatus(this.label);
  final String label;

  static EntryStatus? tryParse(String? raw) {
    if (raw == null) return null;
    final v = raw.trim().toLowerCase();
    for (final s in EntryStatus.values) {
      if (s.label.toLowerCase() == v) return s;
    }
    // Older rows used "Ongoing" before it was renamed to "Reading".
    if (v == 'ongoing') return EntryStatus.reading;
    return null;
  }

  static EntryStatus parse(String? raw) => tryParse(raw) ?? EntryStatus.reading;

  /// Statuses shown on the Library tab (To Read has its own tab).
  static const library = [
    EntryStatus.reading,
    EntryStatus.finished,
    EntryStatus.dropped,
    EntryStatus.cancelled,
  ];
}

/// [Entry.sourceId] value for "looked for it on the sources, found nothing".
/// Stops the background check from searching again every time; linking a
/// source by hand replaces it.
const noSourceFound = 'none';

class Entry {
  const Entry({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    this.chapter = 0,
    this.reread = 0,
    this.chaptersBanked = 0,
    this.rereadOverlap = 0,
    this.position = 0,
    this.createdAt,
    this.coverUrl,
    this.author,
    this.totalChapters,
    this.readOnUrl,
    this.lastReadAt,
    this.sourceId,
    this.latestChapter,
    this.latestCheckedAt,
  });

  final String id;
  final String title;
  final EntryType type;
  final EntryStatus status;
  final int chapter;
  final int reread;

  /// Chapters Stats keeps from earlier read-throughs: set when you add a
  /// reread, so clearing the chapter count to start over doesn't take them
  /// off Stats. See [withChapterAccounting].
  final int chaptersBanked;

  /// How much of [chapter] is already inside [chaptersBanked] (the chapter
  /// you were on when the reread was added), so it isn't counted twice.
  /// Shrinks when [chapter] goes below it.
  final int rereadOverlap;
  final int position;
  final DateTime? createdAt;
  final String? coverUrl;
  final String? author;
  final int? totalChapters;
  final String? readOnUrl;
  final DateTime? lastReadAt;

  /// Where new chapters are checked, e.g. `mangadex:<uuid>`. Null = not
  /// linked yet, [noSourceFound] = searched but no match.
  final String? sourceId;

  /// Newest chapter number the source has (from the update check).
  final int? latestChapter;
  final DateTime? latestCheckedAt;

  bool get isLinked => sourceId != null && sourceId != noSourceFound;

  /// Chapters this title adds to Stats: this read-through plus earlier ones
  /// ([chaptersBanked]). Deleting the title takes all of them off; lowering
  /// [chapter] takes the difference off.
  int get chaptersCounted {
    final n = chaptersBanked + chapter - rereadOverlap;
    return n < 0 ? 0 : n;
  }

  /// Chapters out that you haven't read yet (0 when unknown).
  int get unreadChapters {
    final latest = latestChapter;
    if (latest == null || latest <= chapter) return 0;
    return latest - chapter;
  }

  /// Shows the "New" badge: something you're reading has chapters waiting.
  bool get hasNewChapters =>
      status == EntryStatus.reading && unreadChapters > 0;

  /// How many chapters the series has, as far as we know: the total you or
  /// AniList set, or the newest chapter the source has if that's higher
  /// (ongoing series keep adding chapters past an old total). Null when
  /// neither is known.
  ///
  /// This is chapters *available*. It never feeds into [chapter] (chapters
  /// *read*): a new chapter coming out only moves this number.
  int? get knownChapters {
    final total = totalChapters, latest = latestChapter;
    if (total == null || total <= 0) return (latest ?? 0) > 0 ? latest : null;
    if (latest == null || latest <= total) return total;
    return latest;
  }

  /// 0..1 progress (chapters read / [knownChapters]), or null when the
  /// chapter count is unknown.
  double? get progress {
    final total = knownChapters;
    if (total == null || total <= 0) return null;
    return (chapter / total).clamp(0.0, 1.0).toDouble();
  }

  /// When this title was last "touched" — a chapter bump or when it was added.
  DateTime get activityAt =>
      lastReadAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'].toString(),
        title: (j['title'] as String?) ?? 'Untitled',
        type: EntryType.parse(j['type'] as String?),
        status: EntryStatus.parse(j['status'] as String?),
        chapter: _toInt(j['chapter']) ?? 0,
        reread: _toInt(j['reread']) ?? 0,
        chaptersBanked: _toInt(j['chapters_banked']) ?? 0,
        rereadOverlap: _toInt(j['reread_overlap']) ?? 0,
        position: _toInt(j['position']) ?? 0,
        createdAt: _toDate(j['created_at']),
        coverUrl: j['cover_url'] as String?,
        author: j['author'] as String?,
        totalChapters: _toInt(j['total_chapters']),
        readOnUrl: j['read_on_url'] as String?,
        lastReadAt: _toDate(j['last_read_at']),
        sourceId: j['source_id'] as String?,
        latestChapter: _toInt(j['latest_chapter']),
        latestCheckedAt: _toDate(j['latest_checked_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.label,
        'status': status.label,
        'chapter': chapter,
        'reread': reread,
        'chapters_banked': chaptersBanked,
        'reread_overlap': rereadOverlap,
        'position': position,
        'created_at': createdAt?.toIso8601String(),
        'cover_url': coverUrl,
        'author': author,
        'total_chapters': totalChapters,
        'read_on_url': readOnUrl,
        'last_read_at': lastReadAt?.toIso8601String(),
        'source_id': sourceId,
        'latest_chapter': latestChapter,
        'latest_checked_at': latestCheckedAt?.toIso8601String(),
      };

  Entry copyWith({
    String? title,
    EntryType? type,
    EntryStatus? status,
    int? chapter,
    int? reread,
    int? chaptersBanked,
    int? rereadOverlap,
    int? position,
    DateTime? lastReadAt,
    // Nullable fields use a wrapper so they can be explicitly cleared.
    Nullable<String>? coverUrl,
    Nullable<String>? author,
    Nullable<int>? totalChapters,
    Nullable<String>? readOnUrl,
    Nullable<String>? sourceId,
    Nullable<int>? latestChapter,
    Nullable<DateTime>? latestCheckedAt,
  }) =>
      Entry(
        id: id,
        title: title ?? this.title,
        type: type ?? this.type,
        status: status ?? this.status,
        chapter: chapter ?? this.chapter,
        reread: reread ?? this.reread,
        chaptersBanked: chaptersBanked ?? this.chaptersBanked,
        rereadOverlap: rereadOverlap ?? this.rereadOverlap,
        position: position ?? this.position,
        createdAt: createdAt,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        coverUrl: coverUrl != null ? coverUrl.value : this.coverUrl,
        author: author != null ? author.value : this.author,
        totalChapters:
            totalChapters != null ? totalChapters.value : this.totalChapters,
        readOnUrl: readOnUrl != null ? readOnUrl.value : this.readOnUrl,
        sourceId: sourceId != null ? sourceId.value : this.sourceId,
        latestChapter:
            latestChapter != null ? latestChapter.value : this.latestChapter,
        latestCheckedAt: latestCheckedAt != null
            ? latestCheckedAt.value
            : this.latestCheckedAt,
      );
}

/// Keeps [Entry.chaptersCounted] right when a change from [before] to
/// [after] touches the reread count or the chapter:
///
/// - Adding a reread banks everything counted so far. The chapter you're
///   on overlaps the bank, so the total doesn't jump; clearing the chapter
///   to start over then keeps the total, and reading again adds to it.
/// - Removing a reread keeps the total too (chapters read stay read).
/// - Lowering the chapter outside a reread takes the difference off.
Entry withChapterAccounting(Entry before, Entry after) {
  var banked = after.chaptersBanked;
  var overlap = after.rereadOverlap;
  if (after.reread > before.reread) {
    banked = before.chaptersCounted;
    overlap = before.chapter;
  } else if (after.reread < before.reread && overlap > 0) {
    banked = banked > overlap ? banked - overlap : 0;
    overlap = 0;
  }
  if (overlap > after.chapter) overlap = after.chapter;
  if (overlap < 0) overlap = 0;
  if (banked == after.chaptersBanked && overlap == after.rereadOverlap) {
    return after;
  }
  return after.copyWith(chaptersBanked: banked, rereadOverlap: overlap);
}

/// Lets [Entry.copyWith] tell "leave unchanged" (null) apart from
/// "set to null" (`Nullable(null)`).
class Nullable<T> {
  const Nullable(this.value);
  final T? value;
}

/// A title found on AniList / another tracker, before it's in the list.
class SearchResult {
  const SearchResult({
    required this.id,
    required this.title,
    required this.type,
    this.author,
    this.coverUrl,
    this.totalChapters,
    this.publicationStatus,
    this.description,
    this.averageScore,
    this.source = 'AniList',
  });

  final String id;
  final String title;
  final EntryType type;
  final String? author;
  final String? coverUrl;
  final int? totalChapters;
  final String? publicationStatus;
  final String? description;
  final int? averageScore;
  final String source;
}

int? _toInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

DateTime? _toDate(Object? v) {
  if (v == null) return null;
  return DateTime.tryParse(v.toString())?.toLocal();
}
