/// 调试日志：print 到 logcat + 内存环形缓冲（UI 可显示）+ 落盘文件
/// 文件位置（按可用性择优，用户可用文件管理器找到）：
///   1) 外部存储 App 目录：<external>/logs/app.log（Android/data/.../files/logs/）
///   2) 回退：<docs>/logs/app.log
/// 超 1MB 轮转为 app.1.log
library;

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'policy.dart';

class Dbg {
  static final List<String> _buf = [];
  static const int _max = 300;
  static final List<void Function(String)> _listeners = [];
  static File? _logFile;
  static final List<String> _pending = [];
  static Timer? _flushTimer;

  static void _flushPending(File f) {
    if (_pending.isEmpty) return;
    try {
      f.writeAsStringSync(_pending.join(), mode: FileMode.append, flush: false);
    } catch (_) {}
    _pending.clear();
  }
  static int _logWrites = 0;
  static bool _fileInit = false;

  static List<String> get lines => List.unmodifiable(_buf);

  /// 日志文件路径（供"我的"页展示/分享）
  static Future<String?> filePath() async {
    await _ensureFile();
    return _logFile?.path;
  }

  /// 读取最近日志（优先内存缓冲——只要 App 活着就一定有内容；文件仅导出用）
  static Future<String> recentContent({int lines = 200}) async {
    // 内存缓冲一定有内容（App 启动即写），直接用它
    if (_buf.isNotEmpty) {
      final buf = _buf.length <= lines
          ? _buf
          : _buf.sublist(_buf.length - lines);
      return buf.join('\n');
    }
    await _ensureFile();
    final f = _logFile;
    if (f == null || !await f.exists()) return '（暂无日志）';
    try {
      final all = await f.readAsLines();
      return all.length <= lines
          ? all.join('\n')
          : all.sublist(all.length - lines).join('\n');
    } catch (e) {
      return '（读取失败: $e）';
    }
  }

  /// 把日志导出到公共下载目录（Android/data/<pkg>/files/Download/hls_player_log.txt），
  /// 只含**最后 200 行**（整个文件可达 1MB，没法用微信发）。返回目标路径，失败返回 null。
  static Future<String?> exportToDownload() async {
    final f = _logFile;
    if (f == null || !await f.exists()) return null;
    try {
      // getExternalStorageDirectories(type: downloads) 在 Android 11+ 指向
      // Android/data/<pkg>/files/Download，文件管理器可见
      final dirs = await getExternalStorageDirectories(
          type: StorageDirectory.downloads);
      Directory? dir;
      if (dirs != null && dirs.isNotEmpty) {
        dir = dirs.first;
      } else {
        dir = await getExternalStorageDirectory();
      }
      if (dir == null) return null;
      if (!await dir.exists()) await dir.create(recursive: true);
      final out = File(p.join(dir.path, 'hls_player_log.txt'));
      await out.writeAsString(await recentContent(lines: 200), flush: true);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _ensureFile() async {
    if (_fileInit) return;
    _fileInit = true;
    // 优先外部存储（文件管理器可见），失败回退应用私有目录
    for (final maker in [
      () async {
        final d = await getExternalStorageDirectory();
        return d == null ? null : Directory(p.join(d.path, 'logs'));
      },
      () async {
        final d = await getApplicationDocumentsDirectory();
        return Directory(p.join(d.path, 'logs'));
      },
    ]) {
      try {
        final logs = await maker();
        if (logs == null) continue;
        if (!await logs.exists()) await logs.create(recursive: true);
        final f = File(p.join(logs.path, 'app.log'));
        // 轮转：超过 1MB 改名为 app.1.log
        if (await f.exists() && await f.length() > 1024 * 1024) {
          await f.rename(p.join(logs.path, 'app.1.log'));
        }
        _logFile = f;
        return;
      } catch (_) {
        continue;
      }
    }
    _logFile = null;
  }

  /// 保存抓取到的页面 HTML 到日志目录（page_<name>.html），供离线核对解析规则
  static Future<String?> savePage(String name, String html) async {
    await _ensureFile();
    final f = _logFile;
    if (f == null) return null;
    try {
      final dir = f.parent;
      final out = File('${dir.path}/page_$name.html');
      await out.writeAsString(html, flush: true);
      // 存档上限：只保留最新 30 份，防无上限增长（每份可达 1MB+）
      final pages = dir
          .listSync()
          .whereType<File>()
          .where((x) => x.path.contains('/page_'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (var i = Policy.maxPageArchives; i < pages.length; i++) {
        try {
          await pages[i].delete();
        } catch (_) {}
      }
      return out.path;
    } catch (_) {
      return null;
    }
  }

  static void addListener(void Function(String) fn) => _listeners.add(fn);
  static void removeListener(void Function(String) fn) =>
      _listeners.remove(fn);

  static void log(String s) {
    final line = '${DateTime.now().toString().substring(0, 19)} $s';
    // ignore: avoid_print
    print(line);
    _buf.add(line);
    if (_buf.length > _max) _buf.removeRange(0, _buf.length - _max);
    _appendFile(line);
    for (final fn in List.of(_listeners)) {
      fn(line);
    }
  }

  static void _appendFile(String line) {
    final f = _logFile;
    if (f == null) return;
    // 批量落盘：逐条 sync 写 IO 碎片化（代理分片日志高频），攒批 3s 或 64 条一次写
    _pending.add('$line\n');
    if (_pending.length >= 64) {
      _flushPending(f);
      return;
    }
    _flushTimer ??= Timer(const Duration(seconds: 3), () {
      _flushTimer = null;
      final lf = _logFile;
      if (lf != null) _flushPending(lf);
    });
    // 日志轮转：频繁写入的 app.log 无限增长可吃掉上百 MB（系统"应用管理"比
    // app 内缓存统计大的主要差额来源之一）；每 200 次写入查一次，>5MB 轮转
    if (++_logWrites % 200 == 0) {
      try {
        if (f.lengthSync() > Policy.logRotateBytes) {
          final old1 = File('${f.path}.1');
          if (old1.existsSync()) old1.deleteSync();
          f.renameSync('${f.path}.1');
          _logFile = File(f.path); // 下一轮 _ensureFile / 新写入重建
          _logWrites = 0;
        }
      } catch (_) {}
    }
  }
}
