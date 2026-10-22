import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hls_proxy_player/local_proxy.dart';

void main() {
  group('LocalProxy ⚠️基线（防"null/m3u8"静默失败回归）', () {
    test('未 start 就取 m3u8Url → 必须抛错（禁止拼出 null/...）', () {
      expect(() => LocalProxy.instance.m3u8Url('https://a.com/x.m3u8'),
          throwsStateError);
    });

    test('start 后 m3u8Url 为 127.0.0.1 且带 .m3u8 后缀', () async {
      final base = await LocalProxy.instance.start();
      final url = LocalProxy.instance.m3u8Url('https://a.com/x.m3u8');
      expect(url, startsWith('$base/m3u8/index.m3u8?u='));
      expect(url.contains('.m3u8?u='), isTrue); // ExoPlayer 靠后缀识别 HLS
      expect(url.contains('null'), isFalse);
    });

    test('rewritePlaylist：分片与密钥 URL 全部改写为 /fetch', () {
      const upstream = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/k.key",'
          'IV=0x0102030405060708090a0b0c0d0e0f10\n'
          'https://cdn.example.com/v/seg0.ts\n'
          'seg1.ts\n';
      final out = LocalProxy.rewritePlaylist(upstream, 'https://cdn.example.com/v/x.m3u8');
      final lines = const LineSplitter().convert(out);
      expect(lines[0], '#EXTM3U');
      expect(lines[2], contains('/fetch?u='));
      expect(lines[2], contains('k.key'));
      expect(lines[3], contains('/fetch?u='));
      expect(lines[3], contains('seg0.ts'));
      expect(lines[4], contains('/fetch?u=')); // 相对路径也已解析
      expect(lines[3], startsWith('http://127.0.0.1')); // 全部指向本地代理
    });

    test('rewritePlaylist 保留注释与空行', () {
      final out = LocalProxy.rewritePlaylist(
          '#EXTM3U\n\n#EXT-X-ENDLIST', 'https://a.com/x.m3u8');
      expect(out, '#EXTM3U\n\n#EXT-X-ENDLIST');
    });
  });
}
