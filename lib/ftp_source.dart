/// 内网 FTP 兜底源（app 侧读取自有 NAS 上的已解密短剧）。
///
/// 链路：app → LocalProxy(127.0.0.1) → FtpSource(最小 PASV FTP 客户端) → NAS FTP
///
/// 设计要点（对齐 代码审计与优化建议.md 六、TODO）：
///   1. 内网探测：连接 FTP_HOST 超时 <2s 视为内网；结果会话内缓存，避免每次播放都探测。
///   2. 播放优先级（在 main.dart 中接线）：内网 FTP → 本地缓存 → 外网解析。
///   3. 路径全 ASCII（抓取侧 Method B：中文只进 _map.txt/manifest.json 内容，不进路径），
///      故 FTP 命令路径无需 GBK 编码；_map.txt/manifest.json 以 UTF-8 读内容即可。
///   4. 复用 LocalProxy 通道：分片/合并文件都经 /ftpfetch 流式回传，ExoPlayer 走与
///      在线一致的 HLS-over-proxy 路径，无需新增播放器分支。
///   5. 两种播放形态都支持，运行时可切换测试哪种效果好：
///      - split（分片）：用 manifest.json 的 segs 清单合成 HLS m3u8（已解密，无 EXT-X-KEY）。
///      - merged（合并）：直接播 full.ts 这一整片（单一 TS，定位/拖动最准）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dbg.dart';
import 'local_proxy.dart';

/// FTP 播放形态 (v3.3: 只有 split, merged 已废弃)
enum FtpPlayMode { split }

/// NAS FTP 配置。
///
/// 合规说明：原代码中 host/user/pass 等凭据是**硬编码**在源码里的，会上传明文字据，
/// 已改为从应用私有目录的 `local_config.json` 读取（该文件不进版本库，由用户在设置页填写）。
/// 默认值为空 —— 没有任何内嵌凭据，避免源码泄露私人 NAS 信息。
class FtpConfig {
  static String host = '';
  static int port = 21;
  static String user = '';
  static String pass = '';
  static String root = '';
  static const Duration connectTimeout = Duration(seconds: 2); // 内网探测/连接上限

  /// 控制连接读超时（响应等待）：服务器繁忙时 2s 太紧，会把瞬时抖动放大成致命 404
  static const Duration readTimeout = Duration(seconds: 10);

  /// 是否已配置（host + 凭据齐全才会尝试连接）
  static bool get configured =>
      host.isNotEmpty && user.isNotEmpty && pass.isNotEmpty && root.isNotEmpty;

  /// 从应用私有目录的 local_config.json 加载配置（文件不存在时保持默认空值）。
  static Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path, 'local_config.json'));
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        host = (j['host'] as String?) ?? host;
        port = (j['port'] as int?) ?? port;
        user = (j['user'] as String?) ?? user;
        pass = (j['pass'] as String?) ?? pass;
        root = (j['root'] as String?) ?? root;
        Dbg.log('[FTP] 已从 local_config.json 加载配置: $host');
      } else {
        Dbg.log('[FTP] 无 local_config.json，使用默认空配置（请在设置页填写）');
      }
    } catch (e) {
      Dbg.log('[FTP] 读取配置失败（忽略）: $e');
    }
  }

  /// 保存配置到 local_config.json（运行时由设置页调用）。
  static Future<void> save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path, 'local_config.json'));
      await f.writeAsString(jsonEncode({
        'host': host,
        'port': port,
        'user': user,
        'pass': pass,
        'root': root,
      }), flush: true);
      Dbg.log('[FTP] 配置已保存');
    } catch (e) {
      Dbg.log('[FTP] 保存配置失败: $e');
    }
  }
}

/// 最小 FTP 客户端：仅实现播放所需 —— USER/PASS、PASV、RETR、NLST。
/// 一个实例 = 一条控制连接，串行执行命令；并发传输由 FtpSource 的池/信号量控制。
class _FtpClient {
  final String host;
  final int port;
  final String user;
  final String pass;
  Socket? _ctrl;
  final List<int> _buf = [];
  StreamSubscription<List<int>>? _sub;
  Completer<void> _dataReady = Completer<void>();

  _FtpClient(this.host, this.port, this.user, this.pass);

  /// 单一订阅 + 缓冲：Socket 是单订阅流，不能反复 .first；
  /// 一条监听把字节累加进 _buf 并唤醒等待中的 _readLine。
  void _initReader() {
    _sub = _ctrl!.listen((chunk) {
      _buf.addAll(chunk);
      if (!_dataReady.isCompleted) _dataReady.complete();
    }, onError: (_) {
      if (!_dataReady.isCompleted) _dataReady.complete();
    }, onDone: () {
      if (!_dataReady.isCompleted) _dataReady.complete();
    });
  }

  Future<void> connect() async {
    _ctrl = await Socket.connect(host, port,
        timeout: FtpConfig.connectTimeout);
    _initReader();
    await _expect(220);
    await _send('USER $user');
    await _expect(331);
    await _send('PASS $pass');
    await _expect(230);
    // 二进制模式（默认即可，但显式设一遍更稳）
    await _send('TYPE I');
    await _expect(200);
  }

  Future<void> close() async {
    // 先尽力把 QUIT 发出去（2s 上限：健康连接毫秒级完成）——
    // 直接 destroy 会丢弃未 flush 的缓冲，QUIT 发不到服务器，
    // NAS 会话就一直挂着（上限 10 个），攒满后新连接被静默丢弃
    try {
      _ctrl?.add(utf8.encode('QUIT\r\n'));
      await _ctrl?.flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    // 再硬断兜底（对端已死/超时场景）
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      _ctrl?.destroy();
    } catch (_) {}
    _ctrl = null;
    _sub = null;
  }

  Future<void> _send(String cmd) async {
    if (_ctrl == null) throw StateError('FTP 未连接');
    // 注意：IOSink.write(obj) 会调用 obj.toString()！必须用 add 发原始字节
    _ctrl!.add(utf8.encode('$cmd\r\n'));
    await _ctrl!.flush();
  }

  /// 读一行（直到 \n），处理控制连接的分块到达。
  /// 单一订阅 + 缓冲：只在 _buf 无换行且当前 _dataReady 未就绪时才 await，
  /// 已就绪则重置并继续（重查 _buf），避免"数据已到但 completer 未唤醒"的竞态挂起。
  Future<String> _readLine() async {
    for (;;) {
      final idx = _buf.indexOf(10); // \n
      if (idx >= 0) {
        final lineBytes = _buf.sublist(0, idx);
        _buf.removeRange(0, idx + 1);
        // 去掉可能的 \r
        final length = lineBytes.isNotEmpty && lineBytes.last == 13
            ? lineBytes.length - 1
            : lineBytes.length;
        return utf8.decode(lineBytes.sublist(0, length));
      }
      if (_dataReady.isCompleted) {
        // 已有数据到达（被本函数上一次 await 之外消费/重置），重置后重查 _buf
        _dataReady = Completer<void>();
        continue;
      }
      await _dataReady.future.timeout(FtpConfig.readTimeout,
          onTimeout: () => throw TimeoutException('FTP 控制连接读超时'));
    }
  }

  /// 读一条完整响应（多行以 'code-' 开头，末行 'code ' 结尾），返回 (code, text)
  Future<(int, String)> _readReply() async {
    final sb = StringBuffer();
    int? code;
    while (true) {
      final line = await _readLine();
      sb.writeln(line);
      if (line.length >= 4 &&
          _isDigit(line[0]) &&
          _isDigit(line[1]) &&
          _isDigit(line[2])) {
        if (line[3] == ' ') {
          code = int.parse(line.substring(0, 3));
          break;
        }
        // line[3] == '-'：多行继续
      }
    }
    return (code, sb.toString().trim());
  }

  Future<int> _expect(int want) async {
    final (code, text) = await _readReply();
    if (code != want) {
      throw Exception('FTP 期望 $want 收到 $code: $text');
    }
    return code;
  }

  /// 进入被动模式，返回已连接的数据 Socket（控制连接已收到 227）
  Future<Socket> _pasvData() async {
    await _send('PASV');
    final (code, text) = await _readReply();
    if (code != 227) throw Exception('PASV 失败 $code: $text');
    // 形如 (192,168,0,1,7,138) → ip + port=p1*256+p2
    final m = RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)')
        .firstMatch(text);
    if (m == null) throw Exception('PASV 响应无法解析: $text');
    final ip =
        '${m.group(1)}.${m.group(2)}.${m.group(3)}.${m.group(4)}';
    final p = int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
    return await Socket.connect(ip, p, timeout: FtpConfig.connectTimeout);
  }

  /// 取文件大小（SIZE 命令，须在 TYPE I 下）
  Future<int> size(String path) async {
    await _send('SIZE $path');
    final (code, text) = await _readReply();
    if (code != 213) throw Exception('SIZE 失败 $code: $text');
    final m = RegExp(r'(\d+)\s*$').firstMatch(text);
    if (m == null) throw Exception('SIZE 响应无法解析: $text');
    return int.parse(m.group(1)!);
  }

  /// 打开 RETR 数据连接（调用方负责读数据 + 之后调用 _endTransfer 收尾）
  /// [rest]：断点续传起始字节（REST 命令，须在 RETR 之前发）
  Future<Socket> _openRetr(String path, {int rest = 0}) async {
    if (rest > 0) {
      await _send('REST $rest');
      await _expect(350);
    }
    final data = await _pasvData();
    await _send('RETR $path');
    final (code, text) = await _readReply();
    if (code != 150 && code != 125) {
      await data.close();
      throw Exception('RETR 失败 $code: $text');
    }
    return data;
  }

  /// 收尾：关闭数据连接后读控制连接的最终响应（226/426）
  Future<void> _endTransfer(Socket data) async {
    try {
      data.destroy(); // 硬断：EOF 正常完成与中途截断都直接释放
    } catch (_) {}
    // 服务器在数据传输完成后才发 226/426；读之（忽略结果，容错）
    try {
      await _readReply();
    } catch (_) {}
  }

  // v3.3: STOR 上传 — 把缓存的视频回传 NAS, 下次直接走 FTP 播
  Future<Socket> _openStor(String path) async {
    final data = await _pasvData();
    await _send('STOR $path');
    final (code, text) = await _readReply();
    if (code != 150 && code != 125) {
      await data.close();
      throw Exception('STOR 失败 $code: $text');
    }
    return data;
  }

  Future<void> storBytes(String path, List<int> bytes) async {
    final data = await _openStor(path);
    try {
      data.add(bytes);
      await data.flush();
    } catch (e) {
      throw Exception('STOR 写数据失败: $e');
    }
    await _endTransfer(data);
  }

  Future<void> storStream(String path, Stream<List<int>> stream) async {
    final data = await _openStor(path);
    try {
      await for (final chunk in stream) {
        data.add(chunk);
      }
      await data.flush();
    } catch (e) {
      throw Exception('STOR 流式写失败: $e');
    }
    await _endTransfer(data);
  }

  Future<void> mkd(String path) async {
    await _send('MKD $path');
    try {
      await _expect(257);
    } catch (_) {}
  }

  /// 取小文件全部字节（_map.txt / manifest.json）
  Future<List<int>> retrBytes(String path) async {
    final data = await _openRetr(path);
    final out = <int>[];
    await for (final chunk in data) {
      out.addAll(chunk);
    }
    await _endTransfer(data);
    return out;
  }

  /// NLST 目录：返回条目名列表（不含路径）。
  /// 先 CWD 到目标目录再 NLST（比 "NLST <path>" 跨服务器更稳，Synology 等亦支持）
  Future<List<String>> nlst(String dir) async {
    await _send('CWD $dir');
    final (cwdCode, cwdText) = await _readReply();
    if (cwdCode != 250 && cwdCode != 200) {
      throw Exception('CWD 失败 $cwdCode: $cwdText');
    }
    final data = await _pasvData();
    await _send('NLST');
    final (code, text) = await _readReply();
    if (code != 150 && code != 125) {
      await data.close();
      throw Exception('NLST 失败 $code: $text');
    }
    final out = <int>[];
    await for (final chunk in data) {
      out.addAll(chunk);
    }
    final listing = utf8.decode(out).split('\n');
    await _endTransfer(data);
    return listing
        .map((l) => l.trim().replaceAll('\r', ''))
        .where((l) => l.isNotEmpty)
        .toList();
  }
}

bool _isDigit(String s) => s.length == 1 && s.codeUnitAt(0) >= 48 && s.codeUnitAt(0) <= 57;

/// v3.3: 按前 N 个 = 拆分 (封面 URL 可能含 =)
List<String> _splitEq(String s, int n) {
  final result = <String>[];
  var rest = s;
  for (var i = 1; i < n && rest.isNotEmpty; i++) {
    final idx = rest.indexOf('=');
    if (idx < 0) break;
    result.add(rest.substring(0, idx));
    rest = rest.substring(idx + 1);
  }
  if (rest.isNotEmpty) result.add(rest);
  return result;
}

/// 并发 FTP 会话信号量：避免一次涌出过多连接到 NAS 被限
class _Semaphore {
  final int max;
  int _cur = 0;
  final List<Completer<void>> _waiters = [];
  _Semaphore(this.max);
  Future<void> acquire() async {
    if (_cur < max) {
      _cur++;
      Dbg.log('[FTP][槽] 占用 $_cur/$max');
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    Dbg.log('[FTP][槽] 等待中 ($_cur/$max, 队列${_waiters.length})');
    await c.future;
    Dbg.log('[FTP][槽] 占用 $_cur/$max（排队获得）');
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _cur--;
    }
  }
}

/// FTP 源门面（单例）
/// FTP 目录条目：供浏览 UI 使用（从根 _map.txt 解析剧名+单集）
class FtpDrama {
  final String id; // drama 编号（如 "117"），即 resolveM3u8Url 的 vid
  String name; // 剧名（如 "高三爱情故事"），可能为空
  String cover; // 封面 URL（按 id 匹配网页目录库，可能为空）
  final List<FtpEpisode> eps;
  FtpDrama(this.id, this.name, this.cover, this.eps);
}

class FtpEpisode {
  final int ep; // 集号
  final String dir; // 相对 root 的目录：xiandai/drama_117/ep6_914...
  FtpEpisode(this.ep, this.dir);
}

class FtpSource {
  FtpSource._();
  static final FtpSource instance = FtpSource._();

  /// 运行时可切换的播放形态 (v3.3: 只有 split)
  static FtpPlayMode playMode = FtpPlayMode.split;

  static const int _maxConns = 4;
  static final _Semaphore _sem = _Semaphore(_maxConns);

  /// 会话代号：每次解析播放地址（进剧/切集/重试）自增。
  /// 在途的 /ftpfetch 传输带着旧代号，泵循环发现代号过期立刻断开——
  /// 切集时旧集的传输毫秒级让路，不再和新集抢带宽（实测切集后有 2s 余波+0.01MB 垃圾传输）。
  static int activeGen = 0;

  bool? _intranet; // null=未探测；true/false=已探测并缓存
  DateTime? _probedAt; // 上次探测时间（缓存 60s，WiFi↔流量切换后自动复检）
  DateTime? _downUntil; // FTP 连不上时的冷却期（60s 内不再尝试，防反复硬撞）
  final Map<String, String> _dramaPathCache = {}; // vid → cat/drama_vid

  /// 是否已确认内网可达（会话内缓存，避免每次播放都探测）
  static bool get intranet => instance._intranet ?? false;

  /// 是否处于冷却期（连不上 NAS 后 60s 内不再硬撞）
  bool get _coolingDown {
    final d = _downUntil;
    return d != null && DateTime.now().isBefore(d);
  }

  /// 手机是否接在局域网里（有 WiFi/以太网的私网 IP）。
  /// 流量模式（蜂窝接口 rmnet/ccmni 等）直接判否——零等待跳过 FTP，不撞超时。
  static Future<bool> _hasLanInterface() async {
    try {
      final list = await NetworkInterface.list();
      for (final itf in list) {
        final n = itf.name.toLowerCase();
        // 蜂窝/VPN/隧道接口不算内网
        if (n.contains('rmnet') ||
            n.contains('ccmni') ||
            n.contains('tun') ||
            n.contains('ppp')) {
          continue;
        }
        for (final a in itf.addresses) {
          final ip = a.address;
          final isPrivate = ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
          if (isPrivate) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 探测内网 FTP 是否可达：先判网络类型，再决定是否碰 FTP。
  /// 结果缓存 60s（WiFi↔流量切换后自动复检）。
  Future<bool> probe() async {
    if (!FtpConfig.configured) {
      _intranet = false;
      Dbg.log('[FTP] 未配置 NAS（请在设置页填写 host/账号/目录），跳过 FTP');
      return false;
    }
    if (_coolingDown) {
      Dbg.log('[FTP] 冷却中（连不上 NAS），跳过 FTP');
      return false;
    }
    if (_intranet != null && _probedAt != null) {
      final age = DateTime.now().difference(_probedAt!);
      if (age < const Duration(seconds: 60)) return _intranet!;
    }
    // 第一步：网络类型——没接在局域网（纯流量/无私网 IP）→ 直接判否，零等待
    if (!await _hasLanInterface()) {
      _intranet = false;
      _probedAt = DateTime.now();
      Dbg.log('[FTP] 当前无局域网接口（流量模式），跳过 FTP');
      return false;
    }
    // 第二步：有私网 IP 才做 TCP 探测 NAS（此时超时才有意义）
    try {
      final c = _FtpClient(FtpConfig.host, FtpConfig.port,
          FtpConfig.user, FtpConfig.pass);
      await c.connect();
      await c.close();
      _intranet = true;
      _probedAt = DateTime.now();
      Dbg.log('[FTP] 内网可达：${FtpConfig.host}');
    } catch (e) {
      _intranet = false;
      _probedAt = DateTime.now();
      _downUntil = DateTime.now().add(const Duration(seconds: 60));
      Dbg.log('[FTP] 在局域网但 NAS 连不上，冷却 60s：$e');
    }
    return _intranet!;
  }

  /// 重探测（网络切换后手动调用）
  Future<bool> repropbe() {
    _intranet = null;
    _dramaPathCache.clear();
    return probe();
  }

  /// 用一条独立 FTP 连接执行动作（受信号量限流）
  /// 连接阶段失败（NAS 连不上）→ 进 60s 冷却并重置探测缓存，让 FTP 源暂时让路
  Future<T> _withConn<T>(Future<T> Function(_FtpClient) fn) async {
    await _sem.acquire();
    final c = _FtpClient(
        FtpConfig.host, FtpConfig.port, FtpConfig.user, FtpConfig.pass);
    try {
      await c.connect();
    } catch (e) {
      _downUntil = DateTime.now().add(const Duration(seconds: 60));
      _intranet = null;
      _dramaPathCache.clear();
      Dbg.log('[FTP] 连接失败，冷却 60s：$e');
      _sem.release();
      rethrow;
    }
    try {
      return await fn(c);
    } finally {
      try {
        await c.close();
      } catch (_) {}
      _sem.release();
    }
  }

  final Map<String, Map<int, String>> _catalogCache = {};
  DateTime? _catalogAt;

  /// v3.3: 解析 drama_<vid> 的路径 (新格式 _map.txt: name=epCount=path=cover)
  Future<String?> _dramaRel(String vid) async {
    final cached = _dramaPathCache[vid];
    if (cached != null) return cached;
    final txt = await _withConn((c) async {
      try {
        return utf8.decode(await c.retrBytes('${FtpConfig.root}/_map.txt'));
      } catch (e) {
        Dbg.log('[FTP] 读 _map.txt 失败: $e');
        return '';
      }
    });
    for (final line in txt.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
      final parts = _splitEq(t, 4);
      if (parts.length >= 3 && parts[2].contains('drama_$vid')) {
        _dramaPathCache[vid] = parts[2];
        return parts[2];
      }
    }
    // 兜底：没有 _map.txt 时扫描目录，取首集所在剧目录
    final scanned = await _scanCatalog();
    for (final d in scanned) {
      if (d.id == vid && d.eps.isNotEmpty) {
        final dir = d.eps.first.dir;
        final slash = dir.lastIndexOf('/');
        final path = slash < 0 ? dir : dir.substring(0, slash);
        _dramaPathCache[vid] = path;
        return path;
      }
    }
    return null;
  }

  /// v3.3: 全剧目录索引 — 读 _map.txt (新格式: name=epCount=path=cover)
  /// 建 vid → {集号: 集目录相对路径}。缓存 10 分钟。
  /// 新格式没有 per-ep 行, 这里用 _dramaRel 拿到 drama 路径后构造 ep 目录。
  Future<Map<int, String>?> _catalog(String vid) async {
    if (_catalogCache.isNotEmpty && _catalogAt != null) {
      final age = DateTime.now().difference(_catalogAt!);
      if (age < const Duration(minutes: 10)) return _catalogCache[vid];
    }
    final txt = await _withConn((c) async {
      try {
        return utf8.decode(await c.retrBytes('${FtpConfig.root}/_map.txt'));
      } catch (e) {
        Dbg.log('[FTP] 读 _map.txt 失败: $e');
        return '';
      }
    });
    if (txt.isEmpty) {
      final scanned = await _scanCatalog();
      for (final d in scanned) {
        if (d.id == vid) {
            final m = <int, String>{};
            for (final e in d.eps) {
              m[e.ep] = e.dir;
            }
            return m;
        }
      }
      return null;
    }
    _catalogCache.clear();
    for (final line in txt.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
      final parts = _splitEq(t, 4);
      if (parts.length < 3) continue;
      final path = parts[2];
      final epCount = int.tryParse(parts[1]) ?? 0;
      final vidMatch = RegExp(r'drama_(\d+)').firstMatch(path);
      if (vidMatch == null) continue;
      final dramaId = vidMatch.group(1)!;
      final eps = <int, String>{};
      for (var ep = 1; ep <= epCount; ep++) {
        eps[ep] = '$path/ep$ep';
      }
      _catalogCache[dramaId] = eps;
    }
    _catalogAt = DateTime.now();
    Dbg.log('[FTP][目录] _map.txt 解析: ${_catalogCache.length} 部剧 '
        '（本剧 ${_catalogCache[vid]?.length ?? 0} 集）');
    return _catalogCache[vid];
  }

  /// v3.3: 解析 _map.txt 新格式: 剧名=集数=路径=封面URL
  /// 例: 剧名=5=xiandai/drama_9234=https://example.com/cover/xxx.jpg
  Future<List<FtpDrama>> listCatalog() async {
    if (!await probe()) {
      Dbg.log('[FTP][目录] 内网不可达，跳过');
      return const [];
    }
    final txt = await _withConn((c) async {
      try {
        return utf8.decode(await c.retrBytes('${FtpConfig.root}/_map.txt'));
      } catch (e) {
        Dbg.log('[FTP] 读 _map.txt 失败: $e');
        return '';
      }
    });
    if (txt.isEmpty) return await _scanCatalog();

    final list = <FtpDrama>[];
    for (final raw in txt.split('\n')) {
      final t = raw.trim();
      if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
      final parts = _splitEq(t, 4);
      if (parts.length < 3) continue;
      final name = parts[0];
      final epCount = int.tryParse(parts[1]) ?? 0;
      final path = parts[2];
      final cover = parts.length >= 4 ? parts[3] : '';
      final vidMatch = RegExp(r'drama_(\d+)').firstMatch(path);
      final vid = vidMatch?.group(1) ?? path;
      final eps = <FtpEpisode>[];
      for (var e = 1; e <= epCount; e++) {
        eps.add(FtpEpisode(e, '$path/ep$e'));
      }
      list.add(FtpDrama(vid, name, cover, eps));
    }
    list.sort((a, b) => a.name.compareTo(b.name));
    Dbg.log('[FTP][目录] 解析到 ${list.length} 部剧 (新格式)');
    return list;
  }

  /// 兜底：没有 _map.txt 时，直接扫 FTP 目录。
  /// 规则：带 `drama_` 的文件夹当“剧”，里面 `ep` 开头的子文件夹当“集”。
  /// 尽力而为，任何异常都静默降级为空列表（不影响已有 _map.txt 路径）。
  Future<List<FtpDrama>> _scanCatalog() async {
    try {
      return await _withConn((c) async {
        final out = <FtpDrama>[];
        final top = await c.nlst(FtpConfig.root);
        for (final entry in top) {
          final rel = entry.trim();
          if (rel.isEmpty || rel == '.' || rel == '..') continue;
          final dramaDirs = <String>[];
          if (RegExp(r'drama_(\d+)', caseSensitive: false).hasMatch(rel)) {
            dramaDirs.add(rel);
          } else {
            // 可能是分类目录（如 xiandai/），里面才有 drama_xxx
            try {
              final sub = await c.nlst('${FtpConfig.root}/$rel');
              for (final s in sub) {
                if (RegExp(r'drama_(\d+)', caseSensitive: false).hasMatch(s)) {
                  dramaDirs.add('$rel/$s');
                }
              }
            } catch (_) {}
          }
          for (final dd in dramaDirs) {
            final vidm = RegExp(r'drama_(\d+)', caseSensitive: false).firstMatch(dd);
            final vid = vidm?.group(1) ?? dd;
            List<String> epDirs = [];
            try {
              final eps = await c.nlst('${FtpConfig.root}/$dd');
              epDirs = eps
                  .where((e) => RegExp(r'^ep\d', caseSensitive: false).hasMatch(e.trim()))
                  .toList()
                ..sort((a, b) => _epNum(a).compareTo(_epNum(b)));
            } catch (_) {}
            if (epDirs.isEmpty) continue;
            final eps = <FtpEpisode>[
              for (var i = 0; i < epDirs.length; i++)
                FtpEpisode(i + 1, '$dd/${epDirs[i]}')
            ];
            out.add(FtpDrama(vid, dd, '', eps));
          }
        }
        out.sort((a, b) => a.name.compareTo(b.name));
        Dbg.log('[FTP][扫描] 兜底扫描到 ${out.length} 部剧');
        return out;
      });
    } catch (e) {
      Dbg.log('[FTP][扫描] 兜底扫描失败: $e');
      return const [];
    }
  }

  int _epNum(String s) {
    final m = RegExp(r'(\d+)').firstMatch(s);
    return m != null ? int.parse(m.group(1)!) : 0;
  }

  /// 定位某集目录：cat/drama_vid/ep<ep>_<hash>
  Future<String?> _epDir(String vid, int ep) async {
    final drama = await _dramaRel(vid);
    if (drama == null) return null;
    final entries = await _withConn((c) async {
      try {
        return await c.nlst('${FtpConfig.root}/$drama');
      } catch (e) {
        Dbg.log('[FTP] NLST $drama 失败: $e');
        return <String>[];
      }
    });
    final prefix = 'ep$ep';
    for (final e in entries) {
      // 匹配 ep1 / ep1_3287ec047679
      if (e == prefix || e.startsWith('${prefix}_')) {
        return '$drama/$e';
      }
    }
    return null;
  }

  /// 生成可播放的 m3u8 代理地址（给 VideoPlayerController.networkUrl 用，需以 .m3u8 结尾）
  /// 任何异常都不抛（返回 null）——FTP 出问题绝不能炸掉播放流程，让本地/在线接手
  Future<String?> resolveM3u8Url(String vid, int ep) async {
    if (vid.isEmpty) return null;
    try {
      return await _resolveM3u8Url(vid, ep);
    } catch (e) {
      Dbg.log('[FTP] 解析异常（已忽略，回退本地/在线）: $e');
      return null;
    }
  }

  Future<String?> _resolveM3u8Url(String vid, int ep) async {
    final sw = Stopwatch()..start();
    if (!await probe()) return null;
    Dbg.log('[FTP] 探测+定位耗时 ${sw.elapsedMilliseconds}ms（含内网探测）');
    // 优先用 _map.txt 目录索引（一次读取，存在/不存在零开销判断，集目录直接拿到）
    String? epDir;
    final cat = await _catalog(vid);
    if (cat != null) {
      epDir = cat[ep];
      if (epDir == null) {
        Dbg.log('[FTP] 目录清单里没有 $vid 第$ep集（零开销跳过 FTP）');
        return null;
      }
      // v3.5 fix: _catalog 给的是 ep1 (无 hash), NAS 实际是 ep1_hash
      // 如果 epDir 没有 _, 用 _epDir NLST 找真正的 hash 目录
      if (!epDir.contains('_') || !epDir.contains('hash')) {
        final realDir = await _epDir(vid, ep);
        if (realDir != null) {
          epDir = realDir;
        }
      }
    } else {
      epDir = await _epDir(vid, ep);
      if (epDir == null) {
        Dbg.log('[FTP] 未找到 $vid 第$ep集 目录');
        return null;
      }
    }
    Dbg.log('[FTP] 解析目录总耗时 ${sw.elapsedMilliseconds}ms');
    final base = LocalProxy.instance.baseUrl;
    if (base == null) {
      await LocalProxy.instance.start();
    }
    final b = LocalProxy.instance.baseUrl!;
    Dbg.log('[FTP] 第$ep集 目录=$epDir 模式=split');
    // v3.3: 只有 split 模式 (merged 已废弃)
    activeGen++;
    _playlistCache.clear();
    return '$b/ftpm3u8/index.m3u8?vid=$vid&ep=$ep&dir=${Uri.encodeComponent(epDir)}&mode=split';
  }

  /// 播放列表缓存：ExoPlayer 会短时间内反复请求 m3u8（初始化/出错重试/seek），
  /// 每次都读 FTP 清单会把服务器压垮（实测一次超时→404→播放直接死）。
  /// 按 epDir+mode 缓存 60 秒，重复请求零 FTP 开销。
  static final Map<String, (String, DateTime)> _playlistCache = {};
  static const _playlistTtl = Duration(seconds: 60);

  /// 构建 m3u8 文本（供 LocalProxy /ftpm3u8 调用）
  static Future<String?> buildPlaylist(
      String vid, int ep, String epDir, String mode) async {
    final base = LocalProxy.instance.baseUrl;
    if (base == null) return null;
    final cacheKey = '$epDir|$mode';
    final hit = _playlistCache[cacheKey];
    if (hit != null && DateTime.now().difference(hit.$2) < _playlistTtl) {
      return hit.$1;
    }
    // v3.3: merged 分支已删除 (只有分片 TS)
    // 分片：读 manifest.json 的 segs 清单（失败重试一次，服务器繁忙时第一次常抖动）
    String manifestTxt = '';
    for (var attempt = 1; attempt <= 2; attempt++) {
      manifestTxt = await instance._withConn((c) async {
        try {
          return utf8.decode(
              await c.retrBytes('${FtpConfig.root}/$epDir/manifest.json'));
        } catch (e) {
          Dbg.log('[FTP] 读 manifest.json 失败(第$attempt次): $e');
          return '';
        }
      });
      if (manifestTxt.isNotEmpty) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (manifestTxt.isEmpty) return null;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(manifestTxt) as Map<String, dynamic>;
    } catch (e) {
      Dbg.log('[FTP] manifest.json 解析失败: $e');
      return null;
    }
    final segs = (m['segs'] as List?) ?? [];
    if (segs.isEmpty) return null;
    Dbg.log('[FTP][清单] $epDir 分片数=${segs.length}');
    // 每片用 manifest 里的真实时长（同步侧从源 m3u8 的 EXTINF 抄录）；
    // 旧 manifest 无 dur 字段时退回统一估值（时间轴为近似）
    final sb = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n');
    var estDur = 0.0;
    var realDur = 0.0;
    for (final s in segs) {
      final name = (s as Map)['name'] as String?;
      if (name == null) continue;
      final dur = (s['dur'] as num?)?.toDouble() ?? 10.0;
      realDur += dur;
      estDur += 10.0;
      final path = '${FtpConfig.root}/$epDir/segs/$name';
      sb.write('#EXTINF:${dur.toStringAsFixed(3)},\n'
          '$base/ftpfetch?path=${Uri.encodeComponent(path)}&g=$activeGen\n');
    }
    sb.write('#EXT-X-ENDLIST\n'); // 点播声明：缺了会被 ExoPlayer 当直播流
    Dbg.log('[FTP][清单] 总时长: ${realDur > 0 && realDur != estDur ? '${realDur.toStringAsFixed(1)}s(真实)' : '${estDur.toStringAsFixed(1)}s(估值)'}');
    final body = sb.toString();
    _playlistCache[cacheKey] = (body, DateTime.now());
    return body;
  }

  /// 从 FTP 流式回传文件到 HTTP 响应（供 LocalProxy /ftpfetch 调用）。
  /// 支持 HTTP Range（ExoPlayer 拖动/分段拉流必需）：Range → FTP REST 断点续传。
  /// ExoPlayer abort 请求后可能保留连接但不读数据 → 零窗口 → flush/close 永久挂起。
  /// 全部加超时：超时即作废该连接，槽位照常释放（实测 4 槽被占死导致所有请求排队）。
  static const Duration _flushTimeout = Duration(seconds: 10);

  /// 每次 Range 响应最多回传的字节数（封口窗口）。
  /// ExoPlayer 收满一个窗口后自己发下一个 Range 请求，响应必然快速干净结束。
  static const int _windowBytes = 2 * 1024 * 1024;

  static Future<void> streamFile(String path, HttpRequest req) async {
    final rangeHdr = req.headers.value(HttpHeaders.rangeHeader);
    Dbg.log('[FTP][取] 收到请求 range=$rangeHdr');
    await _sem.acquire();
    final c = _FtpClient(
        FtpConfig.host, FtpConfig.port, FtpConfig.user, FtpConfig.pass);
    Socket? data;
    var staleAborted = false; // 会话过期中止（收尾时 close 必抛，属预期）
    final sw = Stopwatch()..start();
    try {
      await c.connect();
      // Range: bytes=N[-M] → 起始字节 N（拖动/续拉场景），可选终点 M
      var start = 0;
      int? reqEnd;
      int? total;
      if (rangeHdr != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHdr);
        if (m != null) {
          start = int.parse(m.group(1)!);
          if ((m.group(2) ?? '').isNotEmpty) reqEnd = int.parse(m.group(2)!);
        }
      }
      try {
        total = await c.size(path);
      } catch (_) {}
      Dbg.log('[FTP][取] FTP就绪 total=$total start=$start');
      data = await c._openRetr(path, rest: start);
      Dbg.log('[FTP][取] 数据流开始 start=$start');
      // 回传终点：请求带 M 则尊重之，否则按窗口截断（2MB）。
      // 必须封口：全量流式时 ExoPlayer 缓冲够就中止读取并保留连接（不发 RST），
      // 写入侧撞 TCP 零窗口 → addStream 永久挂起占死槽位（实测踩坑）。
      var serveEnd = total ?? (start + _windowBytes);
      if (reqEnd != null) {
        serveEnd = (reqEnd + 1).clamp(start, serveEnd).toInt();
      } else if (total != null) {
        serveEnd = (start + _windowBytes).clamp(start, total).toInt();
      }
      final resp = req.response;
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (total != null) {
        resp.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${serveEnd - 1}/$total');
      }
      resp.contentLength = serveEnd - start;
      resp.headers.contentType = _tsType(path);
      var bytes = 0;
      // 会话代号：URL 带 g=，当前代号变了说明该集已被切走——立刻断开让路
      final gen = int.tryParse(req.uri.queryParameters['g'] ?? '') ?? activeGen;
      // 封口泵：async* 生成器读 FTP 数据流，到 serveEnd 即 break（取消订阅=关数据连接）；
      // addStream 管背压（响应缓冲满时暂停读 FTP），15s 空闲超时防服务器断供。
      Stream<List<int>> pump() async* {
        var sent = 0;
        final want = serveEnd - start;
        await for (final chunk
            in data!.timeout(const Duration(seconds: 15))) {
          if (gen != activeGen) {
            staleAborted = true;
            Dbg.log('[FTP][取] 会话过期，中止 ${_baseName(path)}');
            break;
          }
          if (sent + chunk.length >= want) {
            final take = want - sent;
            bytes += take;
            yield chunk.sublist(0, take);
            break;
          }
          sent += chunk.length;
          bytes += chunk.length;
          yield chunk;
        }
      }

      await resp.addStream(pump());
      sw.stop();
      final mb = bytes / 1024 / 1024;
      final sec = sw.elapsedMilliseconds / 1000;
      Dbg.log('[FTP][传输] ${_baseName(path)}${start > 0 ? "@$start" : ''} '
          '${mb.toStringAsFixed(2)}MB ${sw.elapsedMilliseconds}ms '
          '${sec > 0 ? (mb / sec).toStringAsFixed(2) : '?'}MB/s');
      await c._endTransfer(data); // 截断后服务器回 426/226，读掉即可
      data = null;
      // 会话过期中止时 contentLength 没写满，close() 必抛——这是预期行为，按中止记
      await resp.close().timeout(_flushTimeout);
    } catch (e) {
      if (staleAborted) {
        Dbg.log('[FTP][取] 会话过期中止收尾（预期内）: ${_baseName(path)}');
      } else {
        Dbg.log('[FTP] 取文件失败 $path: $e');
        try {
          req.response.statusCode = 502;
          await req.response.close();
        } catch (_) {}
      }
    } finally {
      if (data != null) {
        try {
          data.destroy(); // 硬断数据连接，服务器立即释放
        } catch (_) {}
      }
      try {
        await c.close();
      } catch (_) {}
      _sem.release();
    }
  }

  static String _baseName(String path) =>
      path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;

  static ContentType _tsType(String path) {
    if (path.endsWith('.ts')) {
      return ContentType('video', 'mp2t');
    }
    if (path.endsWith('.json')) {
      return ContentType('application', 'json', charset: 'utf-8');
    }
    return ContentType('application', 'octet-stream');
  }

  // v3.3: 上传本地文件到 NAS
  Future<bool> uploadFile(String localPath, String remoteRel) async {
    if (!await probe()) return false;
    final file = File(localPath);
    if (!await file.exists()) return false;
    try {
      await _withConn((c) async {
        final parts = remoteRel.split('/');
        if (parts.length > 1) {
          var cur = FtpConfig.root;
          for (final p in parts.sublist(0, parts.length - 1)) {
            if (p.isEmpty) continue;
            cur = '$cur/$p';
            await c.mkd(cur);
          }
        }
        await c.storStream('${FtpConfig.root}/$remoteRel', file.openRead());
      });
      return true;
    } catch (e) {
      Dbg.log('[FTP][上传] 失败: $e');
      return false;
    }
  }

  // v3.5: 上传后更新 _map.txt
  Future<bool> updateMapAfterUpload(String vid, String title, int ep, String epDir) async {
    try {
      final txt = await _withConn((c) async {
        try {
          return utf8.decode(await c.retrBytes('${FtpConfig.root}/_map.txt'));
        } catch (_) { return ''; }
      });
      if (txt.isEmpty) return false;
      final lines = txt.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        final parts = _splitEq(t, 4);
        if (parts.length >= 3 && parts[2].contains('drama_$vid')) {
          return true; // 已在 _map.txt
        }
      }
      final name = title.isNotEmpty ? title : 'drama_$vid';
      lines.add('$name=$ep=xiandai/drama_$vid=');
      await _withConn((c) async {
        await c.storBytes('${FtpConfig.root}/_map.txt', utf8.encode(lines.join('\n')));
      });
      return true;
    } catch (e) {
      Dbg.log('[FTP][Map更新] 失败: $e');
      return false;
    }
  }

  // v3.4: 把封面 URL 写回 _map.txt
  Future<bool> updateCoverInMap(String vid, String coverUrl) async {
    try {
      final txt = await _withConn((c) async {
        try {
          return utf8.decode(await c.retrBytes('${FtpConfig.root}/_map.txt'));
        } catch (_) { return ''; }
      });
      if (txt.isEmpty) return false;
      final lines = txt.split('\n');
      var updated = false;
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
        final parts = _splitEq(t, 4);
        if (parts.length >= 3 && parts[2].contains('drama_$vid')) {
          if (parts.length >= 4) {
            parts[3] = coverUrl;
          } else {
            parts.add(coverUrl);
          }
          lines[i] = parts.join('=');
          updated = true;
          break;
        }
      }
      if (!updated) return false;
      await _withConn((c) async {
        await c.storBytes('${FtpConfig.root}/_map.txt', utf8.encode(lines.join('\n')));
      });
      return true;
    } catch (e) {
      Dbg.log('[FTP][封面回写] 失败: $e');
      return false;
    }
  }
}
