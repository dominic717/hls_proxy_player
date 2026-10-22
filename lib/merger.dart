/// 完整视频合并器：下载 m3u8 全部分片 → AES-128 解密 → 拼接为单个完整 .ts 文件
/// 边下载边缓存（每下载完一片即写入合并文件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'crypto_util.dart';
import 'dbg.dart';
import 'http_fetch.dart';
import 'policy.dart';
import 'priority.dart';

/// 顶层解密任务：Isolate.run 的闭包在顶层函数里创建，
/// 作用域链只含可发送参数，不会携带调用方的 State/Timer
Uint8List _mergeDecryptTask(List<int> raw, List<int> key, List<int> iv) =>
    Uint8List.fromList(CryptoUtil.cbcDecryptBytes(raw, key, iv));

Future<Uint8List> _decryptOffMain(List<int> raw, List<int> key, List<int> iv) =>
    Isolate.run(() => _mergeDecryptTask(raw, key, iv));

class MergeProgress {
  final int done;
  final int total;
  final int bytes;
  MergeProgress(this.done, this.total, this.bytes);
}

class MergeResult {
  final File file;
  final int segments;
  final int bytes;
  MergeResult(this.file, this.segments, this.bytes);
}

class VideoMerger {
  /// 取消令牌：seek 后重启缓存时终止旧合并，避免双份下载抢带宽
  static final Set<String> _cancelTokens = {};

  /// 按 hash 的并发去重表：同一集只允许一个合并任务在跑
  static final Map<String, Future<MergeResult>> _inflight = {};

  /// 请求取消指定 m3u8 的合并任务（按 vid 识别）
  static void cancelMerge(String m3u8Url) => _cancelTokens.add(_videoId(m3u8Url));

  /// 合并入口。
  /// 缓存策略（全部持久化，二次播放零下载）：
  ///   1) 成品 <docs>/merged/<vid>.ts 存在且有 .done 标记 → 直接返回
  ///   2) 分片 <docs>/segments/<vid>/<i>.ts 逐片缓存，中断后重试只补缺的片
  ///   3) 全部分片就位后本地拼接出成品，写 .done 标记
  /// [priorityIndex]：优先下载的分片序号（用户 seek 后从目标位置开始缓存）
  /// 并发去重入口：播放器后台缓存与系列缓存可能同时对同一集发起合并，
  /// 按 hash 复用同一任务，避免双份下载抢带宽、并发写同一 segments 目录
  static Future<MergeResult> merge(String m3u8Url,
      {void Function(MergeProgress)? onProgress,
      void Function(String)? onLog,
      int priorityIndex = 0}) async {
    final vid = _videoId(m3u8Url);
    final existing = _inflight[vid];
    if (existing != null) {
      Dbg.log('[合并] 同集任务进行中，复用结果 hash=${vid.substring(0, 8)}');
      return existing;
    }
    final task = _mergeImpl(m3u8Url,
        onProgress: onProgress, onLog: onLog, priorityIndex: priorityIndex);
    _inflight[vid] = task;
    try {
      return await task;
    } finally {
      if (identical(_inflight[vid], task)) _inflight.remove(vid);
    }
  }

  static Future<MergeResult> _mergeImpl(String m3u8Url,
      {void Function(MergeProgress)? onProgress,
      void Function(String)? onLog,
      int priorityIndex = 0}) async {
    void log(String s) {
      Dbg.log('[合并] $s');
      onLog?.call(s);
    }

    log('开始: $m3u8Url');
    final vid = _videoId(m3u8Url);
    final docs = await getApplicationDocumentsDirectory();
    final outFile = File(p.join(docs.path, 'merged', '$vid.ts'));
    final doneMark = File('${outFile.path}.done');
    if (outFile.existsSync() &&
        outFile.lengthSync() > 1024 &&
        doneMark.existsSync()) {
      log('已有完整缓存，直接播放 (${outFile.lengthSync()}B)');
      return MergeResult(outFile, 0, outFile.lengthSync());
    }
    await outFile.parent.create(recursive: true);
    final segDir = Directory(p.join(docs.path, 'segments', vid));
    await segDir.create(recursive: true);

    // 1. 拉播放列表
    log('拉取播放列表...');
    final body = await _getString(m3u8Url, onLog: log);
    final lines = const LineSplitter().convert(body);
    final segments = <String>[];
    String? keyUri;
    List<int>? iv;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-KEY')) {
        final m = RegExp(r'''URI="([^"]+)"''').firstMatch(line);
        if (m != null) keyUri = m.group(1)!.replaceAll('&amp;', '&');
        final ivm = RegExp(r'''IV=0x([0-9a-fA-F]+)''').firstMatch(line);
        if (ivm != null) iv = _hexToBytes(ivm.group(1)!);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        segments.add(line);
      }
    }
    log('分片数: ${segments.length}, 加密: ${keyUri != null}');
    if (segments.isEmpty) throw Exception('播放列表没有分片');
    _cancelTokens.remove(vid); // 新一次合并清掉旧的取消请求
    bool cancelled() {
      if (_cancelTokens.contains(vid)) {
        log('收到取消请求，终止本次合并');
        return true;
      }
      return false;
    }

    // 2. AES-128 密钥（一并缓存：m3u8 变了 key 也换，按 vid 存）
    List<int>? key;
    if (keyUri != null) {
      final keyFile = File(p.join(segDir.path, 'crypt.key'));
      if (await keyFile.exists() && await keyFile.length() == 16) {
        key = await keyFile.readAsBytes();
        log('密钥: 缓存命中');
      } else {
        log('下载密钥: $keyUri');
        key = await _getBytes(keyUri, onLog: log);
        if (key.length != 16) throw Exception('密钥长度异常: ${key.length}');
        await keyFile.writeAsBytes(key, flush: true);
        log('密钥OK: ${key.length}B');
      }
    }

    // 3. 并发下载（保序落盘）：命中缓存跳过，解密后写分片缓存
    //    下载顺序：从 priorityIndex 开始环形排布（用户 seek 后优先缓存目标位置）
    final segFiles = <File>[];
    int totalBytes = 0;
    // 播放时 2 并发：降并发减少对本就抖动的 CDN 的压力（代理已并行拉播放分片，
    // 合并器再高并发会和播放抢同一批 IP 触发连接重置 → 卡顿）；缓冲门 cacheHold 仍负责让路
    final concurrency = DownloadPriority.playerActive ? 2 : 8;
    var completed = 0;
    final results = List<Uint8List?>.filled(segments.length, null);
    final order = [
      for (var k = 0; k < segments.length; k++)
        (priorityIndex % segments.length + k) % segments.length
    ];
    Future<void> worker(List<int> idxList) async {
      var consecutiveFails = 0;
      for (final i in idxList) {
        if (cancelled()) {
          throw Exception('cancelled');
        }
        // 播放缓冲门：在线播放缓冲不足时暂停缓存下载，优先保播放流畅
        while (DownloadPriority.cacheHold && !cancelled()) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (cancelled()) {
          throw Exception('cancelled');
        }
        final sf = File(p.join(segDir.path, '$i.ts'));
        Uint8List data;
        if (await sf.exists() && await sf.length() > 0) {
          data = await sf.readAsBytes(); // 已解密的缓存
        } else {
          log('分片 $i/${segments.length}...');
          try {
            final raw = await _getBytes(segments[i], onLog: log);
            // 解密在后台 isolate：纯 CPU 的 AES-CBC 在主 isolate 会卡 UI
            // ⚠️ 不能在此处内联 Isolate.run 闭包——VM 发送闭包会带上整条词法
            // 作用域链（worker→merge 的 onProgress→播放器 State→Timer 不可发送）。
            // 必须经顶层函数 _decryptOffMain 隔离上下文。
            if (key != null) {
              data = await _decryptOffMain(raw, key, iv ?? List.filled(16, 0));
            } else {
              data = Uint8List.fromList(raw);
            }
            await sf.writeAsBytes(data, flush: true); // 边下边缓存
            consecutiveFails = 0;
          } catch (e) {
            // 连续失败冷却：CDN/WAF 封禁时停止重试风暴，避免拖垮在线播放
            consecutiveFails++;
            if (consecutiveFails >= Policy.consecutiveFailThreshold) {
              log('连续$consecutiveFails片失败，冷却45秒再继续（降低重试风暴）');
              await Future.delayed(Policy.wafCooldown);
              consecutiveFails = 0;
            }
            rethrow;
          }
        }
        results[i] = data;
        completed++;
        totalBytes += data.length;
        onProgress?.call(MergeProgress(completed, segments.length, totalBytes));
      }
    }

    try {
      await Future.wait([
        for (var w = 0; w < concurrency; w++)
          worker([for (var k = w; k < order.length; k += concurrency) order[k]])
      ]);
    } catch (e) {
      if ('$e'.contains('cancelled')) {
        throw Exception('cancelled'); // 上层按"已被取代"静默处理
      }
      rethrow;
    }
    // 保序写分片文件（并发窗口内的文件在 worker 里已按序写，这里统一确认）
    for (var i = 0; i < segments.length; i++) {
      final sf = File(p.join(segDir.path, '$i.ts'));
      if (!await sf.exists()) {
        await sf.writeAsBytes(results[i]!, flush: true);
      }
      segFiles.add(sf);
    }
    log('分片全部就绪，本地拼接...');

    // 4. 本地拼接成品（分片已就位，纯磁盘操作）
    final sink = outFile.openWrite();
    try {
      for (final sf in segFiles) {
        await sink.addStream(sf.openRead());
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    await doneMark.writeAsString('ok');
    // 成品就位后删除中间分片目录：不删的话每集占双倍空间（分片+成品各一份）
    try {
      if (await segDir.exists()) {
        await segDir.delete(recursive: true);
        log('已清理分片缓存: ${segDir.path}');
      }
    } catch (_) {}
    log('完成: ${outFile.lengthSync()}B');
    return MergeResult(outFile, segments.length, totalBytes);
  }

  static String _videoId(String url) => videoHash(url); // 统一 hash 实现

  /// 启动对账清理：回收磁盘上"不算数"的缓存（app 内统计与系统应用管理不一致的差额）
  /// 启动瞬间无进行中的合并，因此：
  ///   1) segments/ 下所有残留分片目录 = 被取消/失败的半截合并 → 全删
  ///   2) merged/ 下无 .done 标记的半截成品 → 删
  /// 返回回收的字节数（日志用）
  static Future<int> purgeOrphans() async {
    var freed = 0;
    int dirSize(Directory d) {
      var s = 0;
      for (final e in d.listSync(recursive: true)) {
        if (e is File) s += e.lengthSync();
      }
      return s;
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      final segRoot = Directory(p.join(docs.path, 'segments'));
      if (await segRoot.exists()) {
        freed += dirSize(segRoot);
        await segRoot.delete(recursive: true);
      }
      final mergedDir = Directory(p.join(docs.path, 'merged'));
      if (await mergedDir.exists()) {
        for (final e in mergedDir.listSync()) {
          if (e is File &&
              e.path.endsWith('.ts') &&
              !await File('${e.path}.done').exists()) {
            freed += e.lengthSync();
            await e.delete();
          }
        }
      }
      // 日志目录：app.log 超大轮转 + 页面存档超限（旧版本无上限积累上百 MB）
      final logDir = Directory(p.join(docs.path, 'logs'));
      if (await logDir.exists()) {
        for (final e in logDir.listSync().whereType<File>()) {
          final name = e.uri.pathSegments.last;
          if (name == 'app.log' && e.lengthSync() > 10 * 1024 * 1024) {
            freed += e.lengthSync();
            final old1 = File(p.join(logDir.path, 'app.log.1'));
            if (await old1.exists()) await old1.delete();
            await e.rename(old1.path);
          } else if (name.startsWith('page_') || name.endsWith('.log.1')) {
            // page 存档与上一代日志：对账时一律回收（运行中的 30 份上限由 savePage 维护）
            freed += e.lengthSync();
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
      if (freed > 0) Dbg.log('[对账] 启动清理孤儿缓存 ${_mb(freed)}MB');
    } catch (e) {
      Dbg.log('[对账] 清理失败(忽略): $e');
    }
    return freed;
  }

  static String _mb(int b) => (b / 1024 / 1024).toStringAsFixed(1);

  /// 已缓存成品文件（按 hash 定位），无则 null
  static Future<File?> cachedFile(String hash) async {
    final docs = await getApplicationDocumentsDirectory();
    final f = File(p.join(docs.path, 'merged', '$hash.ts'));
    final mark = File('${f.path}.done');
    if (await f.exists() && await f.length() > 1024 && await mark.exists()) {
      return f;
    }
    return null;
  }

  static List<int> _hexToBytes(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }


  // ---------- 网络：统一走 http_fetch（标准 HTTP 拉取，全 App 唯一实现） ----------

  static Future<String> _getString(String url, {void Function(String)? onLog}) =>
      fetchString(url, onLog: onLog);

  static Future<List<int>> _getBytes(String url,
          {void Function(String)? onLog}) =>
      fetchBytes(url, onLog: onLog);
}
