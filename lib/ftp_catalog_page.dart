/// 内网 FTP 资源浏览：读根 _map.txt 列出剧名与单集，点集即用现有 FtpSource 播放器播放。
/// 卡片用 Focus 包裹：首个自动获焦、方向键在卡片间移动、OK/Enter 播放。
///
/// 合规说明：本页只展示**用户自有 NAS**里的媒体，封面来自 NAS 上 _map.txt 自带字段，
/// 不再联网去任何站点抓取封面，从根上移除了站点定向/抓取逻辑。
library;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ftp_source.dart';
import 'cover_image.dart';
import 'tv_keys.dart';

class FtpCatalogPage extends StatefulWidget {
  /// 进入播放：drama 为整部剧，startEp 为起始集（从 1 起）
  final void Function(FtpDrama drama, int startEp) onPlay;
  const FtpCatalogPage({super.key, required this.onPlay});

  @override
  State<FtpCatalogPage> createState() => _FtpCatalogPageState();
}

class _FtpCatalogPageState extends State<FtpCatalogPage> {
  List<FtpDrama> _items = const [];
  bool _loading = true;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final list = await FtpSource.instance.listCatalog();
      final playable = list.where((d) => d.eps.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        _items = playable;
        _loading = false;
        _status = playable.isEmpty ? '内网 FTP 暂无可播放内容（请检查设置）' : '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '加载失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_status.isEmpty ? '没有内容' : _status,
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          childAspectRatio: 0.65,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: _items.length,
        itemBuilder: (ctx, i) {
          final d = _items[i];
          final title = d.name.isNotEmpty ? d.name : 'drama_${d.id}';
          return _FocusCard(
            autofocus: i == 0,
            title: title,
            subtitle: '${d.eps.length} 集',
            tag: '内网',
            cover: d.cover,
            onTap: () => widget.onPlay(d, 1),
          );
        },
      ),
    );
  }
}

/// 遥控器友好卡片：聚焦时高亮边框，OK/Enter 触发 onTap；有封面则显示封面图。
class _FocusCard extends StatelessWidget {
  final bool autofocus;
  final String title;
  final String subtitle;
  final String cover;
  final String? tag;
  final VoidCallback onTap;
  const _FocusCard({
    this.autofocus = false,
    required this.title,
    required this.subtitle,
    this.cover = '',
    this.tag,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasCover = cover.isNotEmpty;
    return Focus(
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && isTvActivateKey(event.logicalKey)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (context) {
        final focused = Focus.of(context).hasFocus;
        final scheme = Theme.of(context).colorScheme;
        return Semantics(
          label: title,
          button: true,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[800],
                border: focused
                    ? Border.all(color: scheme.primary, width: 3)
                    : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasCover) Positioned.fill(child: CoverImage(url: cover)),
                  if (tag != null)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(tag!,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10)),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(subtitle,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white70,
                                )),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
