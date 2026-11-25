/// Kinds of titles the app tracks. Stored in Supabase as their [label].
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

/// Reading status. Stored in Supabase as their [label].
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

/// Columns fetched for an entry — kept in one place so every query agrees.
const entryColumns =
    'id, title, type, chapter, status, reread, created_at, cover_url, author, '
    'total_chapters, read_on_url, last_read_at, position';

class Entry {
  const Entry({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    this.chapter = 0,
    this.reread = 0,
    this.position = 0,
    this.createdAt,
    this.coverUrl,
    this.author,
    this.totalChapters,
    this.readOnUrl,
    this.lastReadAt,
  });

  final String id;
  final String title;
  final EntryType type;
  final EntryStatus status;
  final int chapter;
  final int reread;
  final int position;
  final DateTime? createdAt;
  final String? coverUrl;
  final String? author;
  final int? totalChapters;
  final String? readOnUrl;
  final DateTime? lastReadAt;

  /// 0..1 progress, or null when the total chapter count is unknown.
  double? get progress {
    final total = totalChapters;
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
        position: _toInt(j['position']) ?? 0,
        createdAt: _toDate(j['created_at']),
        coverUrl: j['cover_url'] as String?,
        author: j['author'] as String?,
        totalChapters: _toInt(j['total_chapters']),
        readOnUrl: j['read_on_url'] as String?,
        lastReadAt: _toDate(j['last_read_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.label,
        'status': status.label,
        'chapter': chapter,
        'reread': reread,
        'position': position,
        'created_at': createdAt?.toIso8601String(),
        'cover_url': coverUrl,
        'author': author,
        'total_chapters': totalChapters,
        'read_on_url': readOnUrl,
        'last_read_at': lastReadAt?.toIso8601String(),
      };

  Entry copyWith({
    String? title,
    EntryType? type,
    EntryStatus? status,
    int? chapter,
    int? reread,
    int? position,
    DateTime? lastReadAt,
    // Nullable fields use a wrapper so they can be explicitly cleared.
    Nullable<String>? coverUrl,
    Nullable<String>? author,
    Nullable<int>? totalChapters,
    Nullable<String>? readOnUrl,
  }) =>
      Entry(
        id: id,
        title: title ?? this.title,
        type: type ?? this.type,
        status: status ?? this.status,
        chapter: chapter ?? this.chapter,
        reread: reread ?? this.reread,
        position: position ?? this.position,
        createdAt: createdAt,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        coverUrl: coverUrl != null ? coverUrl.value : this.coverUrl,
        author: author != null ? author.value : this.author,
        totalChapters:
            totalChapters != null ? totalChapters.value : this.totalChapters,
        readOnUrl: readOnUrl != null ? readOnUrl.value : this.readOnUrl,
      );
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
