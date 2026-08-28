import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'book.dart';

/// 应用数据库：书架、书签、章节缓存。
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'moyue.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE books(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE NOT NULL,
            title TEXT NOT NULL,
            format TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            added_at INTEGER NOT NULL DEFAULT 0,
            last_read_at INTEGER NOT NULL DEFAULT 0,
            chapter_index INTEGER NOT NULL DEFAULT 0,
            char_offset INTEGER NOT NULL DEFAULT 0,
            percent REAL NOT NULL DEFAULT 0,
            finished INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            tags TEXT NOT NULL DEFAULT '',
            chapter_count INTEGER NOT NULL DEFAULT 0,
            word_count INTEGER NOT NULL DEFAULT 0,
            imported INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE bookmarks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            chapter_index INTEGER NOT NULL,
            chapter_title TEXT NOT NULL DEFAULT '',
            char_offset INTEGER NOT NULL DEFAULT 0,
            preview TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_bookmarks_book ON bookmarks(book_id)');
        await db.execute('''
          CREATE TABLE chapters(
            book_id INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            title TEXT NOT NULL,
            start_offset INTEGER NOT NULL,
            PRIMARY KEY(book_id, idx),
            FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE
          )
        ''');
      },
    );
  }

  // ---------- 书架 ----------

  Future<List<Book>> allBooks() async {
    final db = await database;
    final rows = await db.query('books', orderBy: 'last_read_at DESC, added_at DESC');
    return rows.map(Book.fromMap).toList();
  }

  Future<Book?> bookByPath(String path) async {
    final db = await database;
    final rows = await db
        .query('books', where: 'path = ?', whereArgs: [path], limit: 1);
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  Future<Book?> bookById(int id) async {
    final db = await database;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Book.fromMap(rows.first);
  }

  Future<int> insertBook(Book b) async {
    final db = await database;
    return db.insert('books', b.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> updateBook(Book b) async {
    final db = await database;
    await db.update('books', b.toMap(), where: 'id = ?', whereArgs: [b.id]);
  }

  Future<void> deleteBooks(List<int> ids) async {
    final db = await database;
    final q = ids.map((_) => '?').join(',');
    await db.delete('books', where: 'id IN ($q)', whereArgs: ids);
  }

  /// 删除文件已丢失的书（路径不存在且非导入副本）。
  Future<void> removeBooksByPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    final db = await database;
    final q = List.filled(paths.length, '?').join(',');
    await db.delete('books', where: 'path IN ($q) AND imported = 0', whereArgs: paths);
  }

  /// 按扫描结果补齐 / 恢复书籍。
  Future<List<String>> scanInsert(List<Book> found) async {
    final inserted = <String>[];
    for (final b in found) {
      final exists = await bookByPath(b.path);
      if (exists == null) {
        final id = await insertBook(b);
        if (id > 0) inserted.add(b.title);
      }
    }
    return inserted;
  }

  // ---------- 书签 ----------

  Future<List<Bookmark>> bookmarksOf(int bookId) async {
    final db = await database;
    final rows = await db.query('bookmarks',
        where: 'book_id = ?', whereArgs: [bookId], orderBy: 'created_at DESC');
    return rows.map(Bookmark.fromMap).toList();
  }

  Future<int> insertBookmark(Bookmark bm) async {
    final db = await database;
    return db.insert('bookmarks', bm.toMap());
  }

  Future<void> deleteBookmark(int id) async {
    final db = await database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- 章节缓存 ----------

  Future<void> saveChapters(int bookId, List<String> titles) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('chapters', where: 'book_id = ?', whereArgs: [bookId]);
    for (int i = 0; i < titles.length; i++) {
      batch.insert('chapters', {
        'book_id': bookId,
        'idx': i,
        'title': titles[i],
        'start_offset': 0,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<String>> loadChapterTitles(int bookId) async {
    final db = await database;
    final rows = await db.query('chapters',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'idx ASC',
        columns: ['title']);
    return rows.map((r) => r['title'] as String).toList();
  }

  Future<void> clearChapters(int bookId) async {
    final db = await database;
    await db.delete('chapters', where: 'book_id = ?', whereArgs: [bookId]);
  }

  /// 书架统计：全部标签。
  Future<Set<String>> allTags() async {
    final db = await database;
    final rows = await db.query('books', columns: ['tags']);
    final set = <String>{};
    for (final r in rows) {
      final t = (r['tags'] as String?) ?? '';
      if (t.isNotEmpty) set.addAll(t.split(',').where((e) => e.isNotEmpty));
    }
    return set;
  }
}
