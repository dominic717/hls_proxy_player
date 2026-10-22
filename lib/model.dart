/// 数据模型：视频条目
class DramaItem {
  final String id; // 视频 ID（如 "12"）
  final String title;
  final String cover; // 封面图 URL（可能为空）
  final String episodes; // 集数信息原文（如 "更新至4集"）
  final String pageUrl; // 详情页地址
  final double score; // 评分（0 = 无）
  final double heat; // 热度（万，0 = 无）
  final List<String> tags; // 题材标签（校园/虐恋...）
  final int epCount; // 解析出的集数（0 = 未知）
  final int epAt; // 更新时间 epoch 秒（0 = 未知）

  DramaItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.episodes,
    required this.pageUrl,
    this.score = 0,
    this.heat = 0,
    this.tags = const [],
    this.epCount = 0,
    this.epAt = 0,
  });

  /// 主要分类（第一个标签，无则"未分类"）
  String get category => tags.isNotEmpty ? tags.first : '未分类';

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'cover': cover,
        'episodes': episodes,
        'page_url': pageUrl,
        'score': score,
        'heat': heat,
        'tags': tags.join(','),
        'ep_count': epCount,
        'ep_at': epAt,
      };

  factory DramaItem.fromMap(Map<String, dynamic> m) => DramaItem(
        id: m['id'] as String,
        title: m['title'] as String,
        cover: (m['cover'] ?? '') as String,
        episodes: (m['episodes'] ?? '') as String,
        pageUrl: (m['page_url'] ?? '') as String,
        score: (m['score'] as num?)?.toDouble() ?? 0,
        heat: (m['heat'] as num?)?.toDouble() ?? 0,
        tags: ((m['tags'] as String?) ?? '')
            .split(',')
            .where((s) => s.trim().isNotEmpty)
            .toList(),
        epCount: (m['ep_count'] as num?)?.toInt() ?? 0,
        epAt: (m['ep_at'] as num?)?.toInt() ?? 0,
      );
}
