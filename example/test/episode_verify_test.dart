import 'package:flutter_test/flutter_test.dart';
import 'package:hls_proxy_player_example/episode_verify.dart';

void main() {
  group('EpisodeVerify 集数校验 ⚠️基线', () {
    setUp(() => EpisodeVerify.resetForTest());

    test('不同 hash/大小 → 判定唯一', () {
      EpisodeVerify.record(
          vid: '12', title: '测试剧', ep: 1,
          hash: 'aaaa1111', bytes: 100 * 1024 * 1024, segs: 40);
      EpisodeVerify.record(
          vid: '12', title: '测试剧', ep: 2,
          hash: 'bbbb2222', bytes: 68 * 1024 * 1024, segs: 29);
      expect(EpisodeVerify.status.contains('互不相同'), isTrue);
    });

    test('hash 相同且大小相同 → 判定两集内容相同并告警', () {
      EpisodeVerify.record(
          vid: '12', title: '测试剧', ep: 1,
          hash: 'aaaa1111', bytes: 100 * 1024 * 1024, segs: 40);
      EpisodeVerify.record(
          vid: '12', title: '测试剧', ep: 2,
          hash: 'aaaa1111', bytes: 100 * 1024 * 1024, segs: 40);
      expect(EpisodeVerify.status.contains('内容相同'), isTrue);
      expect(EpisodeVerify.status.contains('第2集与第1集'), isTrue);
    });

    test('hash 相同但大小不同 → 不算同一视频', () {
      EpisodeVerify.record(
          vid: '12', title: '测试剧', ep: 1,
          hash: 'aaaa1111', bytes: 100 * 1024 * 1024, segs: 40);
      EpisodeVerify.record(
          vid: '12', title: '测试剧', ep: 2,
          hash: 'aaaa1111', bytes: 68 * 1024 * 1024, segs: 29);
      expect(EpisodeVerify.status.contains('互不相同'), isTrue);
    });

    test('同一集重复记录不重复告警', () {
      for (var i = 0; i < 3; i++) {
        EpisodeVerify.record(
            vid: '12', title: '测试剧', ep: 1,
            hash: 'aaaa1111', bytes: 100 * 1024 * 1024, segs: 40);
      }
      expect(EpisodeVerify.status.contains('1 集'), isTrue);
    });
  });
}
