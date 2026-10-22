/// 集数校验器：自动比对每集的 (m3u8 hash, 文件大小, 片数)，
/// 发现"两集内容完全相同"立即告警——用于确认选集面板找到的集数不是同一个视频。
/// 调用点：SeriesCache/_backgroundCache 下载完成时、播放页解析到该集地址时。
library;

import 'package:hls_proxy_player/dbg.dart';

class _EpInfo {
  final String hash;
  final int bytes;
  final int segs;
  _EpInfo(this.hash, this.bytes, this.segs);
}

class EpisodeVerify {
  EpisodeVerify._();
  static final Map<String, Map<int, _EpInfo>> _byDrama = {};
  static String status = ''; // 供 UI 展示

  /// 记录一集的身份信息并自动与其他集比对
  static void record({
    required String vid,
    required String title,
    required int ep,
    required String hash,
    required int bytes,
    required int segs,
  }) {
    if (vid.isEmpty || hash.isEmpty) return;
    final m = _byDrama.putIfAbsent(vid, () => <int, _EpInfo>{});
    final prev = m[ep];
    if (prev != null &&
        prev.hash == hash &&
        prev.bytes == bytes &&
        prev.segs == segs) {
      return; // 同一集重复记录，跳过
    }
    m[ep] = _EpInfo(hash, bytes, segs);
    // 与其他集逐一比对（hash 相同且大小相同 = 同一个视频）
    for (final e in m.entries) {
      if (e.key == ep) continue;
      final o = e.value;
      if (o.hash == hash && o.bytes == bytes) {
        status = '⚠️ $title 第$ep集与第${e.key}集内容相同';
        Dbg.log('[校验] ⚠️ $title 第$ep集 与 第${e.key}集 内容完全相同'
            '（hash=${hash.substring(0, 8)} 大小=${_mb(bytes)}MB）——集数映射可能有误');
        return;
      }
    }
    Dbg.log('[校验] ✓ $title 第$ep集 唯一'
        '（hash=${hash.substring(0, 8)} 片数=$segs 大小=${_mb(bytes)}MB）');
    status = '$title 已校验 ${m.length} 集，内容互不相同';
  }

  static String _mb(int b) => (b / 1024 / 1024).toStringAsFixed(1);

  /// 测试用：清空状态
  static void resetForTest() {
    _byDrama.clear();
    status = '';
  }
}
