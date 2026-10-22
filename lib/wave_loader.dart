/// 统一加载反馈控件：ShimmerBar（黑白渐变往返扫动的渐进式进度条）
/// + LoadingOverlay（全屏加载遮罩，唯一入口）
library;

import 'package:flutter/material.dart';

/// 黑白渐变扫动进度条：深色轨道上一段黑白渐变往返移动（渐进式效果）
class ShimmerBar extends StatefulWidget {
  final double height;
  final double? width; // null = 撑满父级
  final double radius;
  const ShimmerBar(
      {super.key, this.height = 6, this.width, this.radius = 3});
  @override
  State<ShimmerBar> createState() => _ShimmerBarState();
}

class _ShimmerBarState extends State<ShimmerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bar = AnimatedBuilder(
      animation: _c,
      builder: (_, __) => ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: Container(
          color: Colors.white.withValues(alpha: 0.14), // 深色轨道
          height: widget.height,
          child: Align(
            alignment: Alignment(-1 + 2 * _c.value, 0), // -1 → 1 往返
            child: FractionallySizedBox(
              widthFactor: 0.42,
              child: Container(
                height: widget.height,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [
                    Colors.white,
                    Colors.black45,
                    Colors.white,
                  ], stops: [0.1, 0.5, 0.9]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return widget.width == null
        ? SizedBox(height: widget.height, child: bar)
        : SizedBox(width: widget.width, height: widget.height, child: bar);
  }
}

/// 统一全屏加载遮罩：深灰渐变背景（明确"加载页"而非黑屏）+ 标题 + shimmer 条 + 副文案
class LoadingOverlay extends StatelessWidget {
  final String text;
  final String? subText;
  const LoadingOverlay({super.key, required this.text, this.subText});
  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2A2A32), Color(0xFF16161C)],
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 18),
            const ShimmerBar(height: 7),
            if (subText != null) ...[
              const SizedBox(height: 12),
              Text(subText!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}
