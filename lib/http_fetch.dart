/// 公共 HTTP 取流模块：标准的 m3u8 / 分片 / 密钥下载。
///
/// 合规说明：本模块只做「常规 HTTP 拉取」，不实现任何反爬/抗封/TLS 指纹伪造/DoH 换 IP
/// 等规避手段。对于自签名证书仅在内网私有网段（RFC1918 / 本机回环）放行，公网一律校验证书，
/// 避免 badCertificateCallback 被滥用为「接受任意证书」的中间人风险。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 从 m3u8/分片 URL 提取视频 hash（缓存键）。
/// 优先匹配常见路径 /videosN/<hash>/；不匹配时回退 URL 的 md5（稳定，跨版本一致）。
String videoHash(String url) {
  final m = RegExp(r'/videos\d+/([a-f0-9]{8,})/').firstMatch(url);
  if (m != null) return m.group(1)!;
  // 兜底：剥离 query（auth_key 每次变化，参与 hash 会导致同视频缓存失配）
  return md5.convert(utf8.encode(url.split('?').first)).toString();
}

/// GET 文本（播放列表等），底层同 fetchBytes
Future<String> fetchString(String url, {void Function(String)? onLog}) async {
  final bytes = await fetchBytes(url, onLog: onLog);
  return utf8.decode(bytes, allowMalformed: true);
}

/// GET 字节（分片/密钥）。支持自定义请求头（如标准 Referer/User-Agent）。
/// 使用标准 Dart HTTP 客户端，证书校验遵循系统信任链（内网私有段自签名证书例外）。
Future<List<int>> fetchBytes(String url,
    {Map<String, String>? headers,
    void Function(String)? onLog}) async {
  final uri = Uri.parse(url);
  final client = HttpClient();
  // 仅对私有网段 / 本机回环放行自签名证书（如家庭 NAS 的自签 HTTPS）。
  // 公网地址一律拒绝无效证书，防止中间人。
  client.badCertificateCallback = (cert, host, port) => _isPrivate(host);
  try {
    final req = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    if (headers != null) {
      headers.forEach((k, v) => req.headers.set(k, v));
    }
    final resp = await req.close().timeout(const Duration(seconds: 30));
    if (resp.statusCode == 404 || resp.statusCode == 410) {
      throw Exception('HTTP ${resp.statusCode} ($url) 无此资源');
    }
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode} ($url)');
    }
    final out = <int>[];
    await for (final chunk in resp) {
      out.addAll(chunk);
    }
    onLog?.call('HTTP ${resp.statusCode} (${out.length}B) $url');
    return out;
  } finally {
    client.close(force: true);
  }
}

/// 是否为私有/本机地址：仅这些地址才允许自签名证书。
bool _isPrivate(String host) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  // IPv4 私有段
  if (host.startsWith('192.168.')) return true;
  if (host.startsWith('10.')) return true;
  if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) return true;
  // 链路本地
  if (host.startsWith('169.254.')) return true;
  return false;
}
