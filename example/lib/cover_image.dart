/// 封面图控件：直接显示图片 URL（支持 http/https 或本地文件路径），带内存+磁盘缓存与失败占位。
/// 不再对图片做任何站点特定的解密——通用播放器只渲染用户明确提供的、可公开访问的封面。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'wave_loader.dart'; // 复用 ShimmerBar（与播放器同一份）

class CoverImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  const CoverImage({super.key, required this.url, this.fit = BoxFit.cover});

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  Uint8List? _bytes;
  bool _failed = false;

  static final Map<String, Uint8List> _memCache = {};
  static int _activeDownloads = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  /// 稳定缓存键：去掉查询串的路径（auth_key 等每次渲染都变，不能进键）
  static String _cacheKey(String url) {
    try {
      return Uri.parse(url).replace(query: '').toString();
    } catch (_) {
      return url;
    }
  }

  /// 本地文件路径：直接读本地（如 file:// 或绝对路径）
  bool get _isLocal =>
      widget.url.startsWith('/') || widget.url.startsWith('file://');

  Future<void> _load() async {
    final key = _cacheKey(widget.url);
    final mem = _memCache[key];
    if (mem != null) {
      if (mounted) setState(() => _bytes = mem);
      return;
    }
    if (_isLocal) {
      try {
        final f = File(widget.url.replaceFirst('file://', ''));
        if (await f.exists()) {
          final b = await f.readAsBytes();
          _memCache[key] = b;
          if (mounted) setState(() => _bytes = b);
          return;
        }
      } catch (_) {}
      if (mounted) setState(() => _failed = true);
      return;
    }
    // 1) 磁盘缓存命中 → 不联网
    try {
      final f = await _diskFile(widget.url);
      if (await f.exists()) {
        final b = await f.readAsBytes();
        _memCache[key] = b;
        if (mounted) setState(() => _bytes = b);
        return;
      }
    } catch (_) {}
    // 2) 联网下载：并发限流，避免首开密集请求
    while (_activeDownloads >= 2) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _activeDownloads++;
    try {
      final req = await HttpClient()
          .getUrl(Uri.parse(widget.url))
          .timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) {
        final b = await resp.fold<List<int>>(
            <int>[], (p, e) => p..addAll(e));
        _memCache[key] = Uint8List.fromList(b);
        if (mounted) setState(() => _bytes = Uint8List.fromList(b));
        try {
          final f = await _diskFile(widget.url);
          await f.writeAsBytes(_memCache[key]!, flush: true);
        } catch (_) {}
      } else if (mounted) {
        setState(() => _failed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _activeDownloads--;
    }
  }

  static Future<File> _diskFile(String url) async {
    final dir = await getTemporaryDirectory();
    final covers = Directory('${dir.path}/covers');
    if (!await covers.exists()) await covers.create(recursive: true);
    final key = _cacheKey(url);
    return File('${covers.path}/${key.hashCode.toUnsigned(63).toRadixString(36)}.img');
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!,
          fit: widget.fit, width: double.infinity, gaplessPlayback: true);
    }
    return Container(
      color: Colors.grey[300],
      child: _failed
          ? const Icon(Icons.broken_image)
          : const Center(
              child: SizedBox(
                  width: 14, height: 14, child: ShimmerBar(width: 60, height: 8))),
    );
  }
}
