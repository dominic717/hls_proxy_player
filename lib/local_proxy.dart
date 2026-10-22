/// 本地代理播放层：播放器 ↔ 127.0.0.1 本地代理 ↔ FTP / 标准 HTTP 通道
///
/// 动机：把播放请求全部改道 localhost 代理，统一经 http_fetch 拉取
/// （内网 FTP 分片走自带的最小 PASV FTP 客户端，外网 m3u8/分片走标准 HTTP）。
/// 代理负责把 FTP 分片与上游分片重写为本机地址，供播放器直接消费。
///
/// 端点：
///   /ftpm3u8?vid=&ep=&dir=&mode= → 读 NAS manifest 生成 m3u8
///   /ftpfetch?path=                → FTP 文件流式取回
///   /m3u8?u=<encodeURIComponent(上游m3u8)>  → 拉播放列表并把分片/密钥 URL 重写为本代理
///   /fetch?u=<encodeURIComponent(分片/密钥)> → 标准 HTTP 拉取并回传字节
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dbg.dart';
import 'http_fetch.dart';
import 'ftp_source.dart';

class LocalProxy {
  LocalProxy._();
  static final LocalProxy instance = LocalProxy._();

  HttpServer? _server;
  String? _base; // http://127.0.0.1:<port>

  /// 代理根地址（公开，供 FTP 源拼装端点地址）
  String? get baseUrl => _base;

  /// 启动（幂等），返回代理根地址
  Future<String> start() async {
    if (_server != null && _base != null) return _base!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _base = 'http://127.0.0.1:${server.port}';
    Dbg.log('[代理] 本地代理已启动 ${_base!}');
    server.listen((req) {
      _handle(req).catchError((e) {
        Dbg.log('[代理] 请求处理异常: $e');
        try {
          req.response.statusCode = 502;
          req.response.close();
        } catch (_) {}
      });
    });
    return _base!;
  }

  /// 代理后的 m3u8 地址（给 VideoPlayerController 用）
  /// 路径必须以 .m3u8 结尾：ExoPlayer 靠 URL 后缀推断媒体类型，
  /// 否则会被当成渐进式文件而报 "None of the available extractors"
  /// 未 start() 就调用 → 抛错（防止拼出 null/... 静默失败）
  String m3u8Url(String upstream) {
    final base = _base;
    if (base == null) {
      throw StateError('本地代理未启动：必须先 await LocalProxy.instance.start()');
    }
    return '$base/m3u8/index.m3u8?u=${Uri.encodeComponent(upstream)}';
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    Dbg.log('[代理] 请求 $path');
    try {
      if (path.startsWith('/ftpm3u8')) {
        // FTP 播放列表：按 vid/ep/dir/mode 生成 m3u8（分片或合并）
        final vid = req.uri.queryParameters['vid'];
        final epS = req.uri.queryParameters['ep'];
        final dir = req.uri.queryParameters['dir'];
        final mode = req.uri.queryParameters['mode'] ?? 'split';
        if (vid == null || epS == null || dir == null) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final ep = int.tryParse(epS) ?? 1;
        final body =
            await FtpSource.buildPlaylist(vid, ep, dir, mode);
        if (body == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        Dbg.log('[代理][FTP] 生成 m3u8 模式=$mode 长度=${body.length}');
        req.response.headers.contentType = ContentType(
            'application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.add(utf8.encode(body));
        await req.response.close();
      } else if (path.startsWith('/ftpfetch')) {
        // FTP 文件流式取回：path=FTP 绝对路径
        final p = req.uri.queryParameters['path'];
        if (p == null || p.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        await FtpSource.streamFile(p, req);
      } else if (path.startsWith('/m3u8')) {
        final upstream = req.uri.queryParameters['u'];
        if (upstream == null || upstream.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final body = await fetchString(upstream,
            onLog: (s) => Dbg.log('[代理][m3u8] $s'));
        final rewritten = rewritePlaylist(body, upstream);
        // 诊断：重写结果（首 6 行）
        final head = const LineSplitter()
            .convert(rewritten)
            .where((l) => l.isNotEmpty)
            .take(6)
            .join(' | ');
        Dbg.log('[代理][m3u8] 重写头6行: $head');
        req.response.headers.contentType = ContentType(
            'application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.add(utf8.encode(rewritten));
        await req.response.close();
      } else if (path == '/fetch') {
        final upstream = req.uri.queryParameters['u'];
        if (upstream == null || upstream.isEmpty) {
          req.response.statusCode = 400;
          await req.response.close();
          return;
        }
        final data = await fetchBytes(upstream,
            onLog: (s) => Dbg.log('[代理][分片] $s'));
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.contentLength = data.length;
        req.response.add(data);
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (e) {
      Dbg.log('[代理] $path 失败: $e');
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 把播放列表里的分片/密钥 URL 全部改写为代理 /fetch 端点（公开以便基线测试）
  static String rewritePlaylist(String body, String m3u8Url) {
    final base = Uri.parse(m3u8Url);
    final out = <String>[];
    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty) {
        out.add('');
        continue;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        out.add(line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (m) {
          final abs = _abs(base, m.group(1)!);
          return 'URI="${_proxyFetch(abs)}"';
        }));
        continue;
      }
      if (line.startsWith('#')) {
        out.add(line);
        continue;
      }
      // 分片行（可能是相对路径）
      out.add(_proxyFetch(_abs(base, line)));
    }
    return out.join('\n');
  }

  static String _abs(Uri base, String ref) =>
      base.resolve(ref).toString();

  static String _proxyFetch(String upstream) =>
      '${instance._base}/fetch?u=${Uri.encodeComponent(upstream)}';
}
