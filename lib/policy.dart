/// 运行策略常量（调参只改这里）。
/// 原 site_config.dart 中与特定站点相关的字段（域名、UA、referer）已随合规改造移除，
/// 仅保留与具体站点无关的通用运行策略。
library;

class Policy {
  /// 分片下载连续失败后的冷却时长（退避，避免重试风暴拖垮在线播放）
  static const Duration wafCooldown = Duration(seconds: 45);

  /// 播放失败自动重试间隔与次数上限
  static const Duration autoRetryInterval = Duration(seconds: 20);
  static const int maxAutoRetry = 30;

  /// 封面下载并发上限
  static const int coverConcurrency = 2;

  /// 日志轮转阈值（字节）
  static const int logRotateBytes = 5 * 1024 * 1024;

  /// 页面 HTML 存档保留份数
  static const int maxPageArchives = 30;

  /// 进程级剧集缓存上限（剧数；LRU 淘汰）
  static const int maxDramaCacheEntries = 10;

  /// episodes 表地址记录保留天数
  static const int episodeUrlRetentionDays = 30;

  /// 分片下载连续失败次数触发冷却
  static const int consecutiveFailThreshold = 2;
}
