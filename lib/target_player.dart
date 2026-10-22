/// target 风格播放器 UI：点屏幕显隐控制层（不自动隐藏、不自动全屏）
/// 顶部：返回 + 标题
/// 底部：三色进度条（已播红/缓冲白/未播灰）+ 时间 → 倍速 | 全屏
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'dbg.dart';
import 'tv_keys.dart';
import 'wave_loader.dart';

// 遥控器"确认/OK"键判定统一用 tv_keys.dart 的 isTvActivateKey()
// (之前本文件单独定义 _tvOkKeyId + _isActivateKey, 与 main.dart/ftp_catalog_page.dart
// 重复且 key 集合不一致 — 现收敛到 tv_keys.dart 一处维护)

/// 遥控器/触摸双兼容按钮：可聚焦 + 聚焦白框高亮 + OK/选择键即点击。
/// 电视遥控器是方向键+OK，普通 IconButton/GestureDetector 不带焦点管理，
/// 控制条出现后没有按钮获焦、方向键无从走起——用它包一层即可遥控可达。
class _RemoteBtn extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool autofocus;
  final GlobalKey<_RemoteBtnState>? btnKey;
  final ValueChanged<bool>? onFocusChange;
  // v3: 可选 UP 回调 — 按上方向键时调用 (用于 button→进度条 回退)
  final VoidCallback? onArrowUp;
  // v3: 可选外部 FocusNode (进度条按 DOWN 时直接 requestFocus, 比 GlobalKey 可靠)
  final FocusNode? focusNode;
  const _RemoteBtn(
      {this.btnKey,
      required this.child,
      this.onTap,
      this.autofocus = false,
      this.onFocusChange,
      this.onArrowUp,
      this.focusNode});

  @override
  State<_RemoteBtn> createState() => _RemoteBtnState();
}

class _RemoteBtnState extends State<_RemoteBtn> {
  // v3: 用外部传入的 focusNode (如有), 否则自建
  FocusNode get _node => widget.focusNode ?? _internalNode;
  late final FocusNode _internalNode = FocusNode();
  late final void Function() _focusListener;

  /// 供外部（如倍速弹窗关闭后）把焦点还给本按钮
  void requestFocus() => _node.requestFocus();

  @override
  void initState() {
    super.initState();
    _focusListener = () {
      if (!mounted) return;  // v3 fix (review M2): 防 dispose 后焦点事件触发 setState 崩溃
      widget.onFocusChange?.call(_node.hasFocus);
      setState(() {});
    };
    _node.addListener(_focusListener);
  }

  @override
  void dispose() {
    // v3: 移除监听 (外部 node 不 dispose, 只移除 listener; 自建 node 才 dispose)
    _node.removeListener(_focusListener);
    if (widget.focusNode == null) _internalNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      key: widget.btnKey,
      canRequestFocus: true,
      autofocus: widget.autofocus,
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent) {
          if (isTvActivateKey(e.logicalKey)) {
            widget.onTap?.call();
            return KeyEventResult.handled;
          }
          // v3: UP 回调 — 按钮按上方向键回进度条
          if (e.logicalKey == LogicalKeyboardKey.arrowUp &&
              widget.onArrowUp != null) {
            widget.onArrowUp!();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            border: _node.hasFocus
                ? Border.all(color: Colors.white, width: 2)
                : null,
            borderRadius: BorderRadius.circular(22),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class TargetPlayer extends StatefulWidget {
  final VideoPlayerController controller;
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onEnded; // 播放完成（自动下一集）
  final String? episodesLabel; // 底部选集入口文字（如"选集 · 全10集"）
  final VoidCallback? onEpisodes; // 打开选集列表
  final int currentEp; // 当前集
  final int totalEps; // 总集数
  final ValueChanged<int>? onSwitchEp; // 点击集数切换
  final Set<int> cachedEps; // 已缓存集号（绿点标识）
  final double initialSpeed; // 初始倍速（连播/切集保持）
  final ValueChanged<double>? onSpeedChanged; // 倍速变化回传（页面持久化）
  final double cacheExtent; // 底部细条：本地已缓存比例（0-1，本地文件=1）
  final ValueChanged<Duration>? onSeek; // 用户 seek（点击/拖拽结束）回调
  final bool loading; // 播放页处于切集/重连等加载态（底部进度条显示波动动画）
  // v3.2: 全屏状态双向通知 — TargetPlayer 更新它, PlayerScreen 的 PopScope 读它决定 BACK → 退出全屏还是退出播放页
  final ValueNotifier<bool>? fullscreenNotifier;
  const TargetPlayer({
    this.fullscreenNotifier,
    super.key,
    required this.controller,
    required this.title,
    this.loading = false,
    this.onBack,
    this.onEnded,
    this.episodesLabel,
    this.onEpisodes,
    this.currentEp = 1,
    this.totalEps = 0,
    this.onSwitchEp,
    this.cachedEps = const {},
    this.initialSpeed = 1.0,
    this.onSpeedChanged,
    this.cacheExtent = 0.0,
    this.onSeek,
  });

  @override
  State<TargetPlayer> createState() => _TargetPlayerState();
}

class _TargetPlayerState extends State<TargetPlayer>
    with WidgetsBindingObserver {
  bool _showControls = true;
  bool _locked = false; // 用户是否全屏锁定（唯一方向状态）
  bool _immersiveLandscape = false; // 沉浸式去重（内部）
  late double _speed = widget.initialSpeed;
  double? _dragValue; // 拖拽中的预览位置

  // 柔和配色（低饱和，避免刺眼）：当前集暗红 / 已缓存绿
  static const Color curEpBg = Color(0xFFA85555);
  static const Color cachedGreen = Color(0xFF6FA96F);

  static const List<double> speeds = [0.75, 1.0, 1.5, 2.0]; // 0.5/1.25 没啥用，去掉

  bool _endedFired = false;

  // 当前焦点是否在某个控制按钮（播放/倍速/全屏）上：为 true 时左右方向键走按钮间导航，
  // 否则左右键直接快进/快退（TV 习惯：看片时左右就是 seek，无需先聚焦进度条）
  bool _controlFocused = false;

  /// 倍速按钮的 Focus 句柄：弹出倍速菜单关闭后，把焦点还给它，
  /// 否则电视上焦点常丢失在 bottom sheet，方向键再也走不到右侧全屏按钮。
  final GlobalKey<_RemoteBtnState> _speedBtnKey = GlobalKey<_RemoteBtnState>();
  // v3: 播放按钮的 Focus 句柄 — 供 _thinBar 按 DOWN 时把焦点送到播放按钮 (bar→buttons 导航)。

  // 全屏切换的可见提示（电视本就横屏，单纯藏控制条看不出变化，需文字反馈）
  String? _fsHint;
  Timer? _fsHintTimer;
  void _showFsHint(String t) {
    setState(() => _fsHint = t);
    _fsHintTimer?.cancel();
    _fsHintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _fsHint = null);
    });
  }

  // v2 修复 (focus nav gap): 进度条的稳定 FocusNode, 供外部 (outer Focus 的 onKeyEvent)
  // 在用户按"下"时把焦点还回控制条。之前 outer Focus 不处理 DOWN → 焦点从控制条按"上"
  // 跑到视频区后, 再按"下"回不来 → "从底部菜单栏选中上方视频, 不能切换底部菜单栏"。
  final FocusNode _barFocus = FocusNode(debugLabel: 'playerProgressBar');
  // v3.2: 播放器整体 FocusNode — 全屏时控制条隐藏, _barFocus detach, 需要 _playerFocus 保持焦点
  // 这样全屏下 D-pad 左右 = seek (outer Focus 的 onKeyEvent 处理)
  final FocusNode _playerFocus = FocusNode(debugLabel: 'playerOuter');
  // v3: 播放按钮的稳定 FocusNode — 进度条按 DOWN 时直接 requestFocus (GlobalKey 方式
  // 在某些 build 周期 currentState 为 null → 焦点死锁, FocusNode 更可靠)。
  final FocusNode _playFocus = FocusNode(debugLabel: 'playerPlayButton');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onTick);
    // v3.2: 监听 fullscreenNotifier — PlayerScreen 的 PopScope 可以通过它让 TargetPlayer 退出全屏
    widget.fullscreenNotifier?.addListener(_onFullscreenChanged);
    if (_speed != 1.0) widget.controller.setPlaybackSpeed(_speed);
    // 进入播放页必须恢复自由旋转：退出时锁过竖屏(portraitUp)，不恢复则
    // 物理横屏永远不切（v1.2.52）；然后跟随当前姿态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      didChangeMetrics();
    });
  }

  /// 物理旋转屏幕 → 自动跟随横/竖屏（用户锁定横屏时除外）
  /// 注意：自动跟随【不锁方向】——一旦 setPreferredOrientations 锁死横屏，
  /// 转回竖屏时窗口不再变化、本回调也不再触发，App 会卡在侧屏
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _locked) return;
      final size = MediaQuery.of(context).size;
      _applyImmersive(size.width > size.height);
    });
  }

  /// 沉浸式跟随横竖（带去重；横竖与否是窗口尺寸的派生值，不是手工维护的状态）
  void _applyImmersive(bool landscape) {
    if (_immersiveLandscape == landscape) return;
    _immersiveLandscape = landscape;
    SystemChrome.setEnabledSystemUIMode(landscape
        ? SystemUiMode.immersiveSticky
        : SystemUiMode.edgeToEdge);
  }

  @override
  void didUpdateWidget(covariant TargetPlayer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      // 控制器被替换（连播/切集）：监听换绑 + 倍速补应用到新控制器
      old.controller.removeListener(_onTick);
      widget.controller.addListener(_onTick);
      _endedFired = false;
      if (_speed != 1.0) widget.controller.setPlaybackSpeed(_speed);
    }
  }

  void _onTick() {
    final v = widget.controller.value;
    // 拖拽进度过程中不触发自动切集
    if (_dragValue != null) return;
    // 播放完成 → 触发一次自动下一集
    if (v.duration.inMilliseconds > 0 &&
        !v.isBuffering &&
        v.position.inMilliseconds >= v.duration.inMilliseconds - 500 &&
        !_endedFired) {
      _endedFired = true;
      if (widget.onEnded != null) {
        // 延迟到下一事件循环，避免在控制器回调栈里同步销毁控制器导致崩溃
        final cb = widget.onEnded!;
        Future.microtask(cb);
        return;
      }
    }
    if (v.position.inMilliseconds < v.duration.inMilliseconds - 1000) {
      _endedFired = false;
    }
    if (mounted) setState(() {});
  }

  void _toggleControls() {
    // 只显隐控制层，不自动全屏/不自动隐藏
    setState(() => _showControls = !_showControls);
  }

  Future<void> _showSpeedMenu() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (ctx) => SafeArea(
        // 横屏时弹窗可用高度不足，固定 Column 会把最后一项（2.0）裁掉且无法滚动
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('播放倍速',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
            ),
            ...speeds.map((sp) => ListTile(
                  dense: true,
                  title: Text('${sp}x',
                      style: TextStyle(
                          fontSize: 13,
                          color: sp == _speed
                              ? Colors.redAccent
                              : Colors.white)),
                  trailing:
                      sp == _speed ? const Icon(Icons.check, color: Colors.redAccent, size: 18) : null,
                  onTap: () {
                    _speed = sp;
                    widget.controller.setPlaybackSpeed(sp);
                    widget.onSpeedChanged?.call(sp); // 回传页面持久化
                    Navigator.pop(ctx);
                    if (mounted) setState(() {});  // v3 fix (review L6): 防弹窗关闭后 setState 崩
                  },
                )),
          ],
        ),
        ),
      ),
    );
    // 弹窗关闭（无论选倍速还是按返回/OK 关）后，把焦点还给倍速按钮，
    // 这样再按一次方向键就能走到右侧的全屏按钮，避免焦点卡死。
    if (mounted) _speedBtnKey.currentState?.requestFocus();
  }

  /// 应用全屏锁定状态：锁定=锁横屏方向+沉浸式；解锁=恢复自由旋转+普通 UI
  Future<void> _applyMode() async {
    if (_locked) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      _applyImmersive(true);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      _applyImmersive(false);
    }
    if (mounted) setState(() {});
  }

  /// 全屏按钮：锁定横屏（再按一次解锁，恢复自由旋转）
  /// 电视上屏幕本就横屏，单锁方向看不出变化——故全屏时连带藏控制条进入干净观看，
  /// 退出全屏再显回控制条，并弹出文字提示，这样遥控按全屏才有明确反馈。
  Future<void> _toggleFullscreen() async {
    _locked = !_locked;
    _showControls = !_locked; // 全屏→藏控制条；退出全屏→显控制条
    _showFsHint(_locked ? '已全屏' : '已退出全屏');
    Dbg.log('[全屏] 点击: 锁定=$_locked 控制条=$_showControls');
    // v3.2: 通知 PlayerScreen 全屏状态 (PopScope 用它判断 BACK → 退出全屏 vs 退出播放页)
    widget.fullscreenNotifier?.value = _locked;
    await _applyMode();
    // v3.2: 进入全屏时焦点给 _playerFocus → 全屏下 D-pad 左右能 seek
    // 退出全屏时焦点给 _barFocus → 控制条可见时进度条获焦
    if (_locked) {
      _playerFocus.requestFocus();
    } else {
      _barFocus.requestFocus();
    }
    if (mounted) setState(() {});
  }

  /// v3.2: 监听 fullscreenNotifier — PopScope 通过设 value=false 让本组件退出全屏
  /// (BACK 键在全屏时应该退出全屏, 不是退出播放页)
  void _onFullscreenChanged() {
    final want = widget.fullscreenNotifier?.value ?? false;
    if (want != _locked) {
      if (!want && _locked) {
        // 退出全屏
        _locked = false;
        _showControls = true;
        _showFsHint('已退出全屏');
        _applyMode();
        _barFocus.requestFocus();
        if (mounted) setState(() {});
      }
    }
  }

  // v3.3 fix: seek 节流 — 防连按快进轰炸 CDN (用户日志: 10秒内 6 次 seek →
  // CDN 限流 → Connection reset → 重建播放器 → 超时 → 黑屏闪退)
  // 短按 = ±10s; 长按(按住/KeyRepeat) = ±30s; 500ms 节流(累积 delta, 一次 seek)
  DateTime? _lastSeekTime;
  int _pendingSeekMs = 0;  // 节流期间累积的 seek 量
  Timer? _seekFlushTimer;
  static const _seekThrottleMs = 500;  // 节流间隔

  /// 相对当前位置偏移 seek — 带节流, 防连按轰炸 CDN
  void _seekBy(Duration delta) {
    final v = widget.controller.value;
    final durMs = v.duration.inMilliseconds;
    if (durMs <= 0) return;

    final now = DateTime.now();
    final deltaMs = delta.inMilliseconds;

    // 累积 delta
    _pendingSeekMs += deltaMs;

    // 如果距离上次 seek 不到 500ms, 不立即 seek, 等 timer
    if (_lastSeekTime != null &&
        now.difference(_lastSeekTime!).inMilliseconds < _seekThrottleMs) {
      // 已有 pending, 累积即可, timer 会 flush
      _seekFlushTimer?.cancel();
      _seekFlushTimer = Timer(const Duration(milliseconds: _seekThrottleMs), () {
        _flushPendingSeek(durMs);
      });
      // 更新拖拽预览位置 (UI 立即响应, 不等 seek)
      if (_dragValue == null) {
        _dragValue = (v.position.inMilliseconds + _pendingSeekMs).toDouble();
      } else {
        _dragValue = (_dragValue! + deltaMs).toDouble();
      }
      _dragValue = _dragValue!.clamp(0.0, durMs.toDouble());
      if (mounted) setState(() {});
      return;
    }

    // 距上次 > 500ms, 立即 seek
    _flushPendingSeek(durMs);
  }

  void _flushPendingSeek(int durMs) {
    if (_pendingSeekMs == 0) return;
    final target = (widget.controller.value.position.inMilliseconds + _pendingSeekMs)
        .clamp(0, durMs);
    _pendingSeekMs = 0;
    _lastSeekTime = DateTime.now();
    _seekFlushTimer?.cancel();
    _seekFlushTimer = null;
    // 清拖拽预览, 切回实际位置
    _dragValue = null;
    widget.controller.seekTo(Duration(milliseconds: target));
    widget.onSeek?.call(Duration(milliseconds: target));
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onTick);
    // v2 修复 (timer leak): _fsHintTimer 未取消 → dispose 后 2s 仍可能 setState 报错/崩溃
    _fsHintTimer?.cancel();
    _seekFlushTimer?.cancel();  // v3.3: cancel seek throttle timer
    // v2 修复 (FocusNode leak): _barFocus 必须显式 dispose
    _barFocus.dispose();
    _playFocus.dispose();
    _playerFocus.dispose();
    widget.fullscreenNotifier?.removeListener(_onFullscreenChanged);
    // 退出播放页恢复自由旋转（不再强制竖屏）：电视是物理横屏，强制 portraitUp 会把
    // 返回的列表页搞成竖屏/letterbox（TV 上"播放→返回"整页报废的根因）。
    // 自由旋转让页面跟随设备物理方向：TV(横屏)→列表横屏，手机(竖屏)→列表竖屏。
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.controller.value;
    // 横竖屏跟随由 didChangeMetrics 统一处理（不在 build 里改状态）
    final pos = _dragValue != null
        ? Duration(milliseconds: _dragValue!.toInt())
        : v.position;
    final dur = v.duration;
    // Focus 包一层：电视遥控在控制条隐藏时按 OK/选择键 → 显示控制条（手机是点屏幕）
    // v3.2: 用 _playerFocus 绑定 — 全屏时控制条隐藏后, _playerFocus 保持焦点
    // → outer Focus 的 onKeyEvent 能收到 D-pad 左右 → 全屏可快进快退
    return Focus(
      focusNode: _playerFocus,
      canRequestFocus: true,
      onKeyEvent: (node, event) {
        // v3.3: KeyRepeatEvent = 长按(按住) → 大跳 ±30s (短按 KeyDown = ±10s)
        // 防连按轰炸 CDN: 节流在 _seekBy 里处理 (500ms 累积, 一次 flush)
        final isSeekKey = event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight;
        if (isSeekKey && (event is KeyDownEvent || event is KeyRepeatEvent)) {
          if (!_controlFocused) {
            final delta = event is KeyRepeatEvent
                ? Duration(seconds: event.logicalKey == LogicalKeyboardKey.arrowRight ? 30 : -30)
                : Duration(seconds: event.logicalKey == LogicalKeyboardKey.arrowRight ? 10 : -10);
            _seekBy(delta);
            return KeyEventResult.handled;
          }
        }
        if (event is KeyDownEvent) {
          // v3: 控制条可见时, 在视频区 (本 Focus 有主焦点) 按 OK → 播放/暂停
          // v3.1 fix: 加 widget.loading 守卫 — 切集/重连时 controller 正在重建,
          //           调 pause/play 会崩 (native crash, logcat 只见 "app died")
          if (isTvActivateKey(event.logicalKey) && _showControls &&
              node.hasPrimaryFocus && !widget.loading) {
            try {
              final ctl = widget.controller;
              ctl.value.isPlaying ? ctl.pause() : ctl.play();
            } catch (_) {}
            return KeyEventResult.handled;
          }
          // 全屏（控制条隐藏）时按 OK/确认：直接退出全屏并显回控制条
          if (isTvActivateKey(event.logicalKey) && !_showControls) {
            _toggleFullscreen();
            return KeyEventResult.handled;
          }
          // v2 修复 (focus nav gap): 控制条可见时, 焦点在视频区 (本 outer Focus 有主焦点) 时,
          // 按"下"把焦点还回进度条。注意: 用 hasPrimaryFocus 限定 — 只在本节点是主焦点
          // (视频区)时触发, 不在子节点 (bar/buttons) 冒泡上来时触发, 否则会把焦点死锁在 bar 上。
          // bar→buttons 的 DOWN 由 _thinBar 的 onKeyEvent 显式处理 (→ _playFocus)。
          if (_showControls &&
              event.logicalKey == LogicalKeyboardKey.arrowDown &&
              node.hasPrimaryFocus) {
            _barFocus.requestFocus();
            return KeyEventResult.handled;
          }
          // v3.3: seek 已在上面 KeyDownEvent/KeyRepeatEvent 统一处理 (短按10s/长按30s/500ms节流)
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls, // 单击：显示/隐藏控制条
      onDoubleTap: () {
        // 双击：播放/暂停（加载态禁用：旧控制器即将被替换，防误播旧集内容）
        if (widget.loading) return;
        final v = widget.controller.value;
        v.isPlaying ? widget.controller.pause() : widget.controller.play();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: ClipRect(
              // 固定自动适应（contain），无缩放选项
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: widget.controller.value.size.width == 0
                      ? 1
                      : widget.controller.value.size.width,
                  height: widget.controller.value.size.height == 0
                      ? 1
                      : widget.controller.value.size.height,
                  child: VideoPlayer(widget.controller),
                ),
              ),
            ),
          ),
          if (_showControls) ...[
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black87
                    ],
                    stops: [0, 0.15, 0.75, 1],
                  ),
                ),
              ),
            ),
            // 顶部：返回 + 标题
            Positioned(
              top: MediaQuery.of(context).padding.top + 4,
              left: 4,
              right: 4,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: widget.onBack ??
                        () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
            // 底部：三色进度条 + 时间 + 控制行
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.of(context).padding.bottom + 4,
              child: GestureDetector(
                // 底部控制块整体消化单击/双击：非按钮区域（集数条空隙、时间文字、
                // 进度条上下边缘）的误触不再冒泡成"切控制条/播放暂停"
                onTap: () {},
                onDoubleTap: () {},
                behavior: HitTestBehavior.translucent,
                // v2 修复: 整个控制条 (集数条+进度条+按钮行) 放进一个 FocusTraversalGroup,
                // 这样 Flutter 默认方向遍历能在 bar↔buttons 之间走 UP/DOWN (之前 buttons 单独
                // 包了 FocusTraversalGroup, 与 bar 不在同一域, 导致 bar 按 DOWN 到不了 buttons)。
                child: FocusTraversalGroup(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 后续集数横滑条（抖音式；纯数字紧凑样式，一屏能放下更多集）
                  if (widget.totalEps > 1 && widget.onSwitchEp != null)
                    // v3.2 fix: Shortcuts 把 LEFT/RIGHT 映射到方向焦点遍历,
                    // 覆盖 ListView 的 Scrollable 默认滚动行为 (Vidda 上被拦截 → 只能看最后一集)
                    Shortcuts(
                      shortcuts: {
                        LogicalKeySet(LogicalKeyboardKey.arrowLeft):
                            DirectionalFocusIntent(TraversalDirection.left),
                        LogicalKeySet(LogicalKeyboardKey.arrowRight):
                            DirectionalFocusIntent(TraversalDirection.right),
                      },
                      child: SizedBox(
                        height: 36,
                        child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: widget.totalEps,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: 6),
                        itemBuilder: (ctx, i) {
                          final e = i + 1;
                          final cur = e == widget.currentEp;
                          final cached = widget.cachedEps.contains(e);
                          // v3: 集数 chip 包 Focus → D-pad 可导航 + OK 可切集 (之前只有 GestureDetector, TV 上摸不到)
                          return Focus(
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  isTvActivateKey(event.logicalKey)) {
                                widget.onSwitchEp!(e);
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: Builder(builder: (ctx) {
                              final focused = Focus.of(ctx).hasFocus;
                              return GestureDetector(
                                onTap: () => widget.onSwitchEp!(e),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: cur
                                        ? curEpBg
                                        : Colors.white.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: focused
                                          ? Colors.white
                                          : (cached
                                              ? cachedGreen
                                              : Colors.transparent),
                                      width: focused ? 2 : (cached ? 1.5 : 0),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('$e',
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: cur
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                              color: cur
                                                  ? Colors.white
                                                  : Colors.white70)),
                                      if (cached)
                                        const SizedBox(width: 3),
                                      if (cached)
                                        const Icon(Icons.check_circle,
                                            size: 11, color: cachedGreen),
                                    ],
                                  ),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    ),
                    ),
                  const SizedBox(height: 2),
                  // v2 修复: 始终渲染 _thinBar (保持 _barFocus 稳定挂载),
                  // 缓冲时把 ShimmerBar 叠在上面, 不再条件替换 → 焦点不再因缓冲丢,
                  // 快进后能继续快进 (锁定在进度条), 也避免 _barFocus detach 导致的崩溃。
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      _thinBar(pos, dur, widget.cacheExtent,
                          autofocus: !_locked,
                          focusNode: _barFocus),
                      if (v.isBuffering || widget.loading)
                        const Positioned.fill(child: ShimmerBar(height: 4)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // v2: 去掉单独的 FocusTraversalGroup (现在整个控制条在一个 group 里),
                  // 让进度条按 DOWN 能走到按钮行
                  Row(
                    children: [
                      // 播放/暂停（最左；亮度降一档不刺眼）；autofocus=遥控器焦点起点
                      // v3: focusNode=_playFocus 供 _thinBar 按 DOWN 时 focus 到这; onArrowUp=回进度条
                      _RemoteBtn(
                        focusNode: _playFocus,
                        autofocus: false,
                        onFocusChange: (f) => setState(() => _controlFocused = f),
                        onArrowUp: () => _barFocus.requestFocus(),
                        // v3 fix (review M3): 读 controller.value.isPlaying 实时状态, 不用 build 时的快照 v
                        onTap: widget.loading
                            ? null
                            : () {
                                final ctl = widget.controller;
                                ctl.value.isPlaying ? ctl.pause() : ctl.play();
                              },
                        child: Icon(
                            v.isPlaying ? Icons.pause_circle : Icons.play_circle,
                            color: Colors.white.withValues(alpha: 0.9),
                            size: 44),
                      ),
                      const Spacer(),
                      // 右侧一组：倍速 → 全屏 → 时间（时间最右）
                      _RemoteBtn(
                        btnKey: _speedBtnKey,
                        onFocusChange: (f) => setState(() => _controlFocused = f),
                        onArrowUp: () => _barFocus.requestFocus(),
                        onTap: _showSpeedMenu,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('${_speed}x 倍速',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 全屏/退出全屏：单按钮（遥控器可达：方向键走到这按OK）
                      _RemoteBtn(
                        onFocusChange: (f) => setState(() => _controlFocused = f),
                        onArrowUp: () => _barFocus.requestFocus(),
                        onTap: _toggleFullscreen,
                        child: Icon(
                          MediaQuery.of(context).size.width >
                                  MediaQuery.of(context).size.height
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('${_fmt(pos)} / ${_fmt(dur)}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ],
                    ),
                ],
              ),
              ),
            ),
            ),
          ],
          // 全屏切换文字提示（独立于控制条：全屏后控制条隐藏，仍要能看到反馈）
          if (_fsHint != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 56,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_fsHint!,
                      style: const TextStyle(color: Colors.white, fontSize: 14)),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  /// 底部细进度条：灰=未缓存 / 白=本地已缓存范围 / 黄=已播，可点击拖拽
  /// [autofocus]：控制条出现时默认聚焦进度条，使左右方向键直接快进/快退。
  /// [focusNode]：稳定 FocusNode, 供外部 (outer Focus 的 onKeyEvent) 在按"下"时把
  /// 焦点还回进度条 (修复"焦点跑到视频区回不来"问题)。
  Widget _thinBar(Duration pos, Duration dur, double cacheExtent,
      {bool autofocus = false, FocusNode? focusNode}) {
    // 三层语义：灰=未缓存（只能在线播） / 白=已缓存到本地（可本地播） / 黄=已播
    final total = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    final played = pos.inMilliseconds.clamp(0, total).toDouble();
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      // 遥控可达：OK=播放/暂停；聚焦后左右方向键 = 快退/快进 10s（TV 无触摸拖拽）
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (isTvActivateKey(event.logicalKey)) {
            final ctl = widget.controller;
            ctl.value.isPlaying ? ctl.pause() : ctl.play();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _seekBy(const Duration(seconds: -10));
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _seekBy(const Duration(seconds: 10));
            return KeyEventResult.handled;
          }
          // v3.1 fix: 进度条按 DOWN → 不再手动 requestFocus (Vidda 上不可靠),
          // 改返回 ignored 让 Flutter FocusTraversalPolicy 默认方向遍历处理。
          // 整个控制条在一个 FocusTraversalGroup 里, 默认遍历能 bar→buttons。
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            return KeyEventResult.ignored;  // 让默认方向遍历接管
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(builder: (bctx) {
        final focused = Focus.of(bctx).hasFocus;
        return LayoutBuilder(builder: (ctx, box) {
          final w = box.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 声明单击/双击：进度条上的点击（含快速双击）都在本组件内消化，
            // 不会冒泡成父层的"切控制条/播放暂停"，避免误碰被当成暂停
            onTap: () {},
            onDoubleTap: () {},
        onHorizontalDragStart: (d) {
          setState(() => _dragValue = d.localPosition.dx / w * total);
        },
        onHorizontalDragUpdate: (d) => setState(() =>
            _dragValue = (d.localPosition.dx / w * total).clamp(0, total)),
        onHorizontalDragEnd: (d) {
          if (_dragValue != null) {
            widget.controller
                .seekTo(Duration(milliseconds: _dragValue!.toInt()));
            widget.onSeek
                ?.call(Duration(milliseconds: _dragValue!.toInt()));
          }
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) setState(() => _dragValue = null);
          });
        },
        // 点击直接跳转到对应位置
        onTapUp: (d) {
          final target =
              (d.localPosition.dx / w * total).clamp(0, total).toInt();
          Dbg.log('[播放] 点击进度条 seek 至 ${_fmt(Duration(milliseconds: target))}');
          widget.controller.seekTo(Duration(milliseconds: target));
          widget.onSeek?.call(Duration(milliseconds: target));
        },
        child: Container(
          height: 30, // 触控区加高（视觉仍是 3px 细条），减少误碰旁边的画面手势
          alignment: Alignment.center,
          decoration: focused
              ? BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(3),
                )
              : null,
          child: Stack(
            children: [
              Container(height: 3, color: Colors.white24),
              FractionallySizedBox(
                // 本地已缓存范围（当前集实际下载到哪，可直接本地播放）
                widthFactor: cacheExtent.clamp(0.0, 1.0),
                child: Container(height: 3, color: Colors.white54),
              ),
              FractionallySizedBox(
                widthFactor: (played / total).clamp(0.0, 1.0),
                child: Container(height: 3, color: const Color(0xFFFFC107)),
              ),
              Positioned(
                left: ((played / total) * w - 5).clamp(0.0, w - 10),
                top: (22 - 10) / 2,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                      color: Color(0xFFFFC107), shape: BoxShape.circle),
                ),
              ),
            ],
          ),
        ),
      );
        });
      }),
    );
  }
}
