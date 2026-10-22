/// 下载优先级门：target 的设计是单一下载流（播放请求即下载）。
/// 有视频在播放时：预热暂停、后台缓存降并发，播放结束恢复。
library;

class DownloadPriority {
  static bool playerActive = false; // 任意播放器正在播放
  static bool cacheHold = false; // 在线播放缓冲不足 → 后台缓存暂停让路（防卡顿）
}
