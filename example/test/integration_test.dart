/// 验证两个库的"实在配合"：hls_rulegen 抽出 m3u8 → hls_proxy_player 的
/// LocalProxy 把它转成本地可播放地址。
import 'package:flutter_test/flutter_test.dart';
import 'package:hls_proxy_player/hls_proxy_player.dart';
import 'package:hls_rulegen/parser.dart';

void main() {
  test('hls_rulegen 抽出的 m3u8 能经 LocalProxy 转成本地播放地址', () async {
    const html = '''
      <video src="https://cdn.example.com/x/index.m3u8"></video>
      <script>window.__c__={"url":"https://cdn.example.com/x/master.m3u8"}</script>
    ''';
    final urls = extractM3u8(html, url: 'https://www.example.com/play');
    expect(urls, isNotEmpty);

    final proxy = LocalProxy.instance;
    final base = await proxy.start();
    final playUrl = proxy.m3u8Url(urls.first);

    expect(playUrl, startsWith(base));
    expect(playUrl, contains('/m3u8/index.m3u8'));
  });
}
