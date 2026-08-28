import '../core/book_format.dart';

/// 书籍来源。
enum BookSource { scanned, imported }

/// 书架中的一本书。
class Book {
  final int? id;
  final String path; // 文件实际位置（扫描原始路径，或导入后的应用内副本路径）
  String title;
  final BookFormat format;
  final int sizeBytes;
  final int addedAt; // 毫秒时间戳
  int lastReadAt; // 0 表示从未读过
  int chapterIndex; // 进度：章索引
  int charOffset; // 进度：章内字符偏移
  double percent; // 0~100
  bool finished; // 已读完
  bool pinned;
  String tags; // 逗号分隔的自定义标签
  int chapterCount;
  int wordCount;
  final bool imported; // true = 应用内私有副本，false = 原位置引用

  Book({
    this.id,
    required this.path,
    required this.title,
    required this.format,
    required this.sizeBytes,
    required this.addedAt,
    this.lastReadAt = 0,
    this.chapterIndex = 0,
    this.charOffset = 0,
    this.percent = 0,
    this.finished = false,
    this.pinned = false,
    this.tags = '',
    this.chapterCount = 0,
    this.wordCount = 0,
    this.imported = false,
  });

  /// 标签列表。
  List<String> get tagList =>
      tags.isEmpty ? const [] : tags.split(',').where((t) => t.isNotEmpty).toList();

  bool get unread => lastReadAt == 0 && percent == 0;

  Book copyWith({
    int? id,
    String? path,
    String? title,
    BookFormat? format,
    int? sizeBytes,
    int? addedAt,
    int? lastReadAt,
    int? chapterIndex,
    int? charOffset,
    double? percent,
    bool? finished,
    bool? pinned,
    String? tags,
    int? chapterCount,
    int? wordCount,
    bool? imported,
  }) {
    return Book(
      id: id ?? this.id,
      path: path ?? this.path,
      title: title ?? this.title,
      format: format ?? this.format,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      addedAt: addedAt ?? this.addedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      charOffset: charOffset ?? this.charOffset,
      percent: percent ?? this.percent,
      finished: finished ?? this.finished,
      pinned: pinned ?? this.pinned,
      tags: tags ?? this.tags,
      chapterCount: chapterCount ?? this.chapterCount,
      wordCount: wordCount ?? this.wordCount,
      imported: imported ?? this.imported,
    );
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'path': path,
        'title': title,
        'format': format.name,
        'size': sizeBytes,
        'added_at': addedAt,
        'last_read_at': lastReadAt,
        'chapter_index': chapterIndex,
        'char_offset': charOffset,
        'percent': percent,
        'finished': finished ? 1 : 0,
        'pinned': pinned ? 1 : 0,
        'tags': tags,
        'chapter_count': chapterCount,
        'word_count': wordCount,
        'imported': imported ? 1 : 0,
      };

  static Book fromMap(Map<String, Object?> m) => Book(
        id: m['id'] as int,
        path: m['path'] as String,
        title: m['title'] as String,
        format: BookFormat.values.firstWhere(
          (f) => f.name == m['format'],
          orElse: () => BookFormat.unknown,
        ),
        sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
        addedAt: (m['added_at'] as num?)?.toInt() ?? 0,
        lastReadAt: (m['last_read_at'] as num?)?.toInt() ?? 0,
        chapterIndex: (m['chapter_index'] as num?)?.toInt() ?? 0,
        charOffset: (m['char_offset'] as num?)?.toInt() ?? 0,
        percent: (m['percent'] as num?)?.toDouble() ?? 0,
        finished: (m['finished'] as int?) == 1,
        pinned: (m['pinned'] as int?) == 1,
        tags: (m['tags'] as String?) ?? '',
        chapterCount: (m['chapter_count'] as num?)?.toInt() ?? 0,
        wordCount: (m['word_count'] as num?)?.toInt() ?? 0,
        imported: (m['imported'] as int?) == 1,
      );
}

/// 书签。
class Bookmark {
  final int? id;
  final int bookId;
  final int chapterIndex;
  final String chapterTitle;
  final int charOffset; // 章内偏移
  final String preview; // 书签处文字预览
  final int createdAt;

  Bookmark({
    this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.charOffset,
    required this.preview,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'chapter_index': chapterIndex,
        'chapter_title': chapterTitle,
        'char_offset': charOffset,
        'preview': preview,
        'created_at': createdAt,
      };

  static Bookmark fromMap(Map<String, Object?> m) => Bookmark(
        id: m['id'] as int,
        bookId: m['book_id'] as int,
        chapterIndex: (m['chapter_index'] as num?)?.toInt() ?? 0,
        chapterTitle: (m['chapter_title'] as String?) ?? '',
        charOffset: (m['char_offset'] as num?)?.toInt() ?? 0,
        preview: (m['preview'] as String?) ?? '',
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      );
}
