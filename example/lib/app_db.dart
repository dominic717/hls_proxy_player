/// 历史记录 + 缓存记录数据库
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class HistoryRec {
  final String vid; // 站点视频 ID
  final String title;
  final int ep; // 集号（1 起）
  final String cover;
  final int watchedAt; // epoch 秒
  final int posSec; // 上次播放到的位置（秒，跨会话断点续播）

  HistoryRec({
    required this.vid,
    required this.title,
    required this.ep,
    required this.cover,
    required this.watchedAt,
    this.posSec = 0,
  });

  factory HistoryRec.fromMap(Map<String, dynamic> m) => HistoryRec(
        vid: m['vid'] as String,
        title: (m['title'] ?? '') as String,
        ep: (m['ep'] as num?)?.toInt() ?? 0,
        cover: (m['cover'] ?? '') as String,
        watchedAt: (m['watched_at'] as num?)?.toInt() ?? 0,
        posSec: (m['pos_sec'] as num?)?.toInt() ?? 0,
      );
}

class CacheRec {
  final String vid;
  final String m3u8Hash; // m3u8 路径里的视频 hash
  final int ep; // 集号
  final String title; // 剧名（与历史记录一致）
  final int segTotal; // 总分片数（0=未知）
  final int segDone; // 已缓存分片数
  final int bytes; // 已缓存字节
  final bool done; // 整集完成
  final int durationSec; // 视频总时长（秒）
  final String error; // 失败原因（空=成功）
  final String pageUrl; // 该集独立页面地址（选集面板懒加载模型；空=旧 slide 模型脏数据）
  final int updatedAt;

  CacheRec({
    required this.vid,
    required this.m3u8Hash,
    required this.ep,
    this.title = '',
    this.segTotal = 0,
    this.segDone = 0,
    this.bytes = 0,
    this.done = false,
    this.durationSec = 0,
    this.error = '',
    this.pageUrl = '',
    this.updatedAt = 0,
  });

  factory CacheRec.fromMap(Map<String, dynamic> m) => CacheRec(
        vid: m['vid'] as String,
        m3u8Hash: (m['m3u8_hash'] ?? '') as String,
        ep: (m['ep'] as num?)?.toInt() ?? 0,
        title: (m['title'] ?? '') as String,
        segTotal: (m['seg_total'] as num?)?.toInt() ?? 0,
        segDone: (m['seg_done'] as num?)?.toInt() ?? 0,
        bytes: (m['bytes'] as num?)?.toInt() ?? 0,
        done: (m['done'] as num?)?.toInt() == 1,
        durationSec: (m['duration_sec'] as num?)?.toInt() ?? 0,
        error: (m['error'] ?? '') as String,
        pageUrl: (m['page_url'] ?? '') as String,
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      );
}

class AppDb {
  static Database? _db;

  static Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  /// 防御性补列：全新安装的 v5 库走 onCreate（已含 pos_sec），但
  /// 某些升级路径可能漏列——缺列会让位置保存/历史写入抛未捕获异常（闪退）
  static Future<void> _ensureColumns(Database d) async {
    for (final sql in [
      'ALTER TABLE history ADD COLUMN pos_sec INTEGER DEFAULT 0',
      'ALTER TABLE cache_records ADD COLUMN page_url TEXT DEFAULT ""',
    ]) {
      try {
        await d.execute(sql);
      } catch (_) {} // 已存在则静默
    }
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final d = await openDatabase(
      p.join(dir, 'app.db'),
      version: 8,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE history(
            vid TEXT, ep INTEGER, title TEXT, cover TEXT,
            pos_sec INTEGER DEFAULT 0,
            watched_at INTEGER,
            PRIMARY KEY(vid, ep)
          )''');
        await d.execute('''
          CREATE TABLE cache_records(
            vid TEXT, m3u8_hash TEXT, ep INTEGER, title TEXT DEFAULT '',
            seg_total INTEGER DEFAULT 0, seg_done INTEGER DEFAULT 0,
            bytes INTEGER DEFAULT 0, done INTEGER DEFAULT 0,
            duration_sec INTEGER DEFAULT 0, error TEXT DEFAULT "",
            page_url TEXT DEFAULT "",
            updated_at INTEGER,
            PRIMARY KEY(vid, m3u8_hash, ep)
          )''');
        await d.execute('''
          CREATE TABLE IF NOT EXISTS episodes(
            vid TEXT, ep INTEGER, page_url TEXT DEFAULT '',
            m3u8 TEXT DEFAULT '', updated_at INTEGER,
            PRIMARY KEY(vid, ep)
          )''');
        // v1.2.132: 通用键值设置表（当前生效的解析规则模板 id 等）
        await d.execute('''
          CREATE TABLE IF NOT EXISTS settings(
            key TEXT PRIMARY KEY, value TEXT DEFAULT ''
          )''');
      },
      onUpgrade: (d, ov, nv) async {
        if (ov < 2) {
          try {
            await d.execute(
                'ALTER TABLE cache_records ADD COLUMN title TEXT DEFAULT ""');
          } catch (_) {}
        }
        if (ov < 3) {
          try {
            await d.execute(
                'ALTER TABLE cache_records ADD COLUMN duration_sec INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (ov < 4) {
          try {
            await d.execute(
                'ALTER TABLE cache_records ADD COLUMN error TEXT DEFAULT ""');
          } catch (_) {}
        }
        if (ov < 5) {
          try {
            await d.execute(
                'ALTER TABLE history ADD COLUMN pos_sec INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (ov < 6) {
          try {
            await d.execute(
                'ALTER TABLE cache_records ADD COLUMN page_url TEXT DEFAULT ""');
          } catch (_) {}
        }
        if (ov < 7) {
          try {
            await d.execute('''
              CREATE TABLE IF NOT EXISTS episodes(
                vid TEXT, ep INTEGER, page_url TEXT DEFAULT '',
                m3u8 TEXT DEFAULT '', updated_at INTEGER,
                PRIMARY KEY(vid, ep)
              )''');
          } catch (_) {}
        }
        if (ov < 8) {
          try {
            await d.execute('''
              CREATE TABLE IF NOT EXISTS settings(
                key TEXT PRIMARY KEY, value TEXT DEFAULT ''
              )''');
          } catch (_) {}
        }
      },
    );
    await _ensureColumns(d);
    return d;
  }

  // ---------- 设置（通用键值） ----------

  /// 读设置项；不存在返回 null
  static Future<String?> getSetting(String key) async {
    try {
      final d = await db;
      final r = await d.query('settings',
          columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
      if (r.isEmpty) return null;
      final v = r.first['value'] as String?;
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// 写设置项；空 value 视为删除该键
  static Future<void> setSetting(String key, String value) async {
    final d = await db;
    if (value.isEmpty) {
      await d.delete('settings', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await d.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------- 历史 ----------

  static Future<void> addHistory({
    required String vid,
    required String title,
    required int ep,
    required String cover,
    int posSec = 0,
  }) async {
    final d = await db;
    // 标题统一存剧名（去掉尾部"第N集"），避免后续拼接出现"第1集第1集"
    title = title.replaceFirst(RegExp(r'\s*第\s*\d+\s*集\s*$'), '');
    // 保留已有位置（未显式传新位置时），避免重复写入把断点清零
    int pos = posSec;
    if (pos <= 0) {
      final rows = await d.query('history',
          where: 'vid = ? AND ep = ?', whereArgs: [vid, ep], limit: 1);
      if (rows.isNotEmpty) {
        pos = (rows.first['pos_sec'] as num?)?.toInt() ?? 0;
      }
    }
    await d.insert(
      'history',
      {
        'vid': vid,
        'ep': ep,
        'title': title,
        'cover': cover,
        'pos_sec': pos,
        'watched_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 更新某条历史的播放位置（跨会话断点）
  static Future<void> updateHistoryPos(String vid, int ep, int posSec) async {
    final d = await db;
    await d.update('history', {'pos_sec': posSec},
        where: 'vid = ? AND ep = ?', whereArgs: [vid, ep]);
  }

  /// 查询某集的上次播放位置（秒，无记录=0）
  static Future<int> historyPos(String vid, int ep) async {
    final d = await db;
    final rows = await d.query('history',
        where: 'vid = ? AND ep = ?', whereArgs: [vid, ep], limit: 1);
    if (rows.isEmpty) return 0;
    return (rows.first['pos_sec'] as num?)?.toInt() ?? 0;
  }

  static Future<List<HistoryRec>> history({int limit = 100}) async {
    final d = await db;
    final rows = await d.query('history',
        orderBy: 'watched_at DESC', limit: limit);
    return rows.map(HistoryRec.fromMap).toList();
  }

  // ---------- 缓存记录 ----------

  static Future<void> upsertCache(CacheRec r) async {
    final d = await db;
    // 清理同 (vid, ep) 的旧 slide 模型脏记录（page_url 为空 = 按 slide 顺序错存的其他剧）
    if (r.pageUrl.isNotEmpty) {
      await d.delete('cache_records',
          where: 'vid = ? AND ep = ? AND (page_url IS NULL OR page_url = \'\')',
          whereArgs: [r.vid, r.ep]);
    }
    await d.insert(
      'cache_records',
      {
        'vid': r.vid,
        'm3u8_hash': r.m3u8Hash,
        'ep': r.ep,
        'title': r.title,
        'seg_total': r.segTotal,
        'seg_done': r.segDone,
        'bytes': r.bytes,
        'done': r.done ? 1 : 0,
        'duration_sec': r.durationSec,
        'error': r.error,
        'page_url': r.pageUrl,
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<CacheRec>> cacheRecords({int limit = 200}) async {
    final d = await db;
    final rows = await d.query('cache_records',
        orderBy: 'updated_at DESC', limit: limit);
    return rows.map(CacheRec.fromMap).toList();
  }

  /// 某视频已完整缓存的集数
  static Future<int> cachedEpCount(String vid) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT COUNT(*) AS n FROM cache_records WHERE vid = ? AND done = 1',
        [vid]);
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// 全部已完成缓存：vid → {集号 → {hash, dur}}
  /// 持久化"集→m3u8 地址"：路径里的 hash 是每集固有指纹（稳定），
  /// 变的只有 query 的 auth_key——存下来配合探针，切集不再抓完整页面
  static Future<void> saveEpisodeUrl(
      {required String vid,
      required int ep,
      required String pageUrl,
      required String m3u8}) async {
    if (vid.isEmpty || m3u8.isEmpty) return;
    final d = await db;
    await d.insert(
        'episodes',
        {
          'vid': vid,
          'ep': ep,
          'page_url': pageUrl,
          'm3u8': m3u8,
          'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 读某集持久化地址（无记录返回 ''）
  static Future<String> episodeUrl(String vid, int ep) async {
    if (vid.isEmpty) return '';
    final d = await db;
    final rows = await d.query('episodes',
        where: 'vid = ? AND ep = ?', whereArgs: [vid, ep], limit: 1);
    if (rows.isEmpty) return '';
    return (rows.first['m3u8'] ?? '') as String;
  }

  /// 清理过期地址记录（默认 30 天；配合启动对账，DB 与磁盘不累积死数据）
  static Future<void> purgeStaleEpisodes({int days = 30}) async {
    final d = await db;
    final cutoff = DateTime.now()
            .subtract(Duration(days: days))
            .millisecondsSinceEpoch ~/
        1000;
    await d.delete('episodes', where: 'updated_at < ?', whereArgs: [cutoff]);
  }

  static Future<Map<String, Map<int, Map<String, dynamic>>>> doneEpMap() async {
    final d = await db;
    // page_url 为空 = 旧 slide 模型的脏记录（集号映射不可信），不得参与本地命中
    final rows = await d.query('cache_records',
        where: "done = 1 AND page_url != ''",
        orderBy: 'updated_at DESC');
    final m = <String, Map<int, Map<String, dynamic>>>{};
    for (final r in rows) {
      final vid = r['vid'] as String;
      final ep = (r['ep'] as num?)?.toInt() ?? 0;
      (m[vid] ??= {})[ep] = {
        'hash': (r['m3u8_hash'] ?? '') as String,
        'dur': (r['duration_sec'] as num?)?.toInt() ?? 0,
      };
    }
    return m;
  }

  /// 清理无法关联的旧记录（vid 为空）
  static Future<void> purgeOrphanCache() async {
    final d = await db;
    await d.delete('cache_records', where: "vid = '' OR vid IS NULL");
  }

  /// 回填旧缓存记录的标题（从历史记录或目录条目）
  static Future<void> backfillCacheTitles(Map<String, String> titleByVid) async {
    final d = await db;
    final rows = await d.query('cache_records',
        where: "title = '' OR title IS NULL");
    for (final r in rows) {
      final vid = r['vid'] as String;
      final t = titleByVid[vid];
      if (t != null && t.isNotEmpty) {
        await d.update('cache_records', {'title': t},
            where: 'vid = ? AND (title = "" OR title IS NULL)', whereArgs: [vid]);
      }
    }
  }

  /// 某视频的缓存分片总数（进行中 + 完成）
  static Future<int> cachedSegCount(String vid) async {
    final d = await db;
    final r = await d.rawQuery(
        'SELECT SUM(seg_done) AS n FROM cache_records WHERE vid = ?', [vid]);
    return Sqflite.firstIntValue(r) ?? 0;
  }
}
