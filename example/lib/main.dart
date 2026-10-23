/// HLS Web Player —— 通用 HLS 播放器（hub 分支）。
///
/// 本分支为合规发布的通用版本，**不包含任何站点定向抓取 / 私有加密破解 / WAF 绕过 / 硬编码凭据**：
///   - 播放任意标准 HLS(m3u8) 地址（用户自行提供的 URL）；
///   - 通过本地代理播放用户自有 NAS(FTP) 上的分片内容；
///   - 可选的 AES-128 解密走 HLS 标准 #EXT-X-KEY（密钥随内容下发），
///     不内置任何第三方的静态密钥。
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'ftp_catalog_page.dart';
import 'package:hls_proxy_player/ftp_source.dart';
import 'package:hls_proxy_player/http_fetch.dart';
import 'package:hls_proxy_player/local_proxy.dart';
import 'package:hls_rulegen/parser.dart';
import 'target_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 凭据从应用私有目录 local_config.json 读取（不进版本库），默认空。
  await FtpConfig.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HLS Web Player',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomePage(),
      );
}

/// 首页：输入 HLS 地址直接播放，或进入内网 FTP 资源库 / 设置。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _urlCtl = TextEditingController();
  final _pageCtl = TextEditingController();
  String? _err;
  bool _busy = false;

  void _playUrl() {
    final url = _urlCtl.text.trim();
    if (url.isEmpty) {
      setState(() => _err = '请输入 m3u8 地址');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen.network(url: url, title: url),
    ));
  }

  /// 配合 hls_rulegen：粘贴播放页 URL → 抓取 HTML → 抽出 m3u8 → 经本地代理播放。
  /// 仅用于你**合法有权限**的站点；本方法不含任何站点专属逻辑。
  Future<void> _parseAndPlay() async {
    final pageUrl = _pageCtl.text.trim();
    if (pageUrl.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入播放页地址')));
      return;
    }
    setState(() => _busy = true);
    try {
      // 1) 抓取播放页源码（标准 HTTP，内网自签证书仅在私有网段放行）
      final html = await fetchString(pageUrl);
      // 2) 通用抽取 m3u8（无规则文件时走通用兜底正则）
      final urls = extractM3u8(html, url: pageUrl);
      if (urls.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('未能从页面解析出 m3u8（可能是非常规播放器结构）')));
        }
        return;
      }
      // 3) 多个则让用户挑一个
      var chosen = urls.first;
      if (urls.length > 1) {
        final picked = await _pickUrl(urls);
        if (picked == null) return; // 用户取消
        chosen = picked;
      }
      // 4) 经本地代理把上游 m3u8 重写到 127.0.0.1 再播放
      final proxy = LocalProxy.instance;
      await proxy.start();
      final playUrl = proxy.m3u8Url(chosen);
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerScreen.network(url: playUrl, title: pageUrl),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('解析失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _pickUrl(List<String> urls) => showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('选择要播放的 m3u8'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: urls.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(urls[i], style: const TextStyle(fontSize: 12)),
                onTap: () => Navigator.of(ctx).pop(urls[i]),
              ),
            ),
          ),
        ),
      );

  @override
  void dispose() {
    _urlCtl.dispose();
    _pageCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 电视版构建时传 --dart-define=IS_TV=true，隐藏反人类的网址输入框
    const isTv = bool.fromEnvironment('IS_TV', defaultValue: false);
    return Scaffold(
      appBar: AppBar(title: const Text('HLS Web Player')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isTv) ...[
              TextField(
                controller: _urlCtl,
                decoration: InputDecoration(
                  labelText: 'HLS (m3u8) 地址',
                  border: const OutlineInputBorder(),
                  errorText: _err,
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _playUrl(),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _playUrl,
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放地址'),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 8),
              TextField(
                controller: _pageCtl,
                decoration: const InputDecoration(
                  labelText: '播放页地址（自动解析 m3u8）',
                  hintText: '粘贴含 m3u8 的播放页 URL，自动抽取后播放',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _parseAndPlay,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_busy ? '解析中…' : '解析并播放'),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => FtpLibraryPage(
                  onPlay: (drama, ep) => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlayerScreen.ftp(drama: drama, startEp: ep),
                    ),
                  ),
                ),
              )),
              icon: const Icon(Icons.folder),
              label: const Text('内网 FTP 资源库'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SettingsPage(),
              )),
              icon: const Icon(Icons.settings),
              label: const Text('设置（NAS / FTP）'),
            ),
            const SizedBox(height: 16),
            const Text(
              '说明：本应用仅用于播放用户自行拥有合法权利的内容。\n'
              'FTP 资源库需先在本机设置页填写 NAS 的地址与账号。',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// 内网 FTP 资源库页面（封装 FtpCatalogPage）。
class FtpLibraryPage extends StatelessWidget {
  final void Function(FtpDrama drama, int startEp) onPlay;
  const FtpLibraryPage({super.key, required this.onPlay});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('内网 FTP 资源库')),
        body: FtpCatalogPage(onPlay: onPlay),
      );
}

/// 播放页：封装 TargetPlayer，支持网络 m3u8 与 FTP 分片两种来源，可切集。
class PlayerScreen extends StatefulWidget {
  final String? url; // 网络源
  final FtpDrama? drama; // FTP 源
  final int startEp;
  final String title;

  const PlayerScreen.network({super.key, required this.url, required this.title})
      : drama = null,
        startEp = 1;

  PlayerScreen.ftp({super.key, required this.drama, this.startEp = 1})
      : url = null,
        title = (drama?.name.isNotEmpty ?? false)
            ? drama!.name
            : 'drama_${drama?.id ?? ''}';

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _ctl;
  int _ep = 1;
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _ep = widget.startEp;
    _init();
  }

  Future<String> _resolveUrl(int ep) async {
    if (widget.url != null) return widget.url!;
    // FTP：经本地代理把内网分片暴露成 m3u8
    final base = await LocalProxy.instance.start();
    final dir = widget.drama!.eps[ep - 1].dir;
    return '$base/ftpm3u8?vid=${widget.drama!.id}&ep=$ep&dir=$dir&mode=split';
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    try {
      final u = await _resolveUrl(_ep);
      final ctl = VideoPlayerController.networkUrl(Uri.parse(u));
      await ctl.initialize();
      ctl.play();
      if (mounted) {
        setState(() {
          _ctl = ctl;
          _loading = false;
          _err = null;
        });
      } else {
        ctl.dispose();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = '播放失败: $e';
        });
      }
    }
  }

  Future<void> _switchEp(int ep) async {
    if (widget.drama == null ||
        ep < 1 ||
        ep > widget.drama!.eps.length) {
      return;
    }
    final old = _ctl;
    setState(() {
      _ep = ep;
      _loading = true;
      _ctl = null;
    });
    await old?.dispose();
    await _init();
  }

  @override
  void dispose() {
    _ctl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.drama?.eps.length ?? 1;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _ctl != null
          ? TargetPlayer(
              controller: _ctl!,
              title: widget.title,
              loading: _loading,
              currentEp: _ep,
              totalEps: total,
              onBack: () => Navigator.of(context).maybePop(),
              onSwitchEp: widget.drama != null ? _switchEp : null,
              episodesLabel: total > 1 ? '选集 · 全$total集' : null,
            )
          : Center(
              child: _err != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_err!,
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center),
                    )
                  : const CircularProgressIndicator(),
            ),
    );
  }
}

/// 设置页：填写 NAS / FTP 连接信息（仅存于本机，不上传）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '21');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _root = TextEditingController();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _host.text = FtpConfig.host;
    _port.text = FtpConfig.port.toString();
    _user.text = FtpConfig.user;
    _pass.text = FtpConfig.pass;
    _root.text = FtpConfig.root;
  }

  Future<void> _save() async {
    FtpConfig.host = _host.text.trim();
    FtpConfig.port = int.tryParse(_port.text.trim()) ?? 21;
    FtpConfig.user = _user.text.trim();
    FtpConfig.pass = _pass.text.trim();
    FtpConfig.root = _root.text.trim();
    await FtpConfig.save();
    if (mounted) setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(_host, 'FTP 主机 (如 192.168.1.100)'),
          _field(_port, '端口', TextInputType.number),
          _field(_user, '用户名'),
          _field(_pass, '密码', TextInputType.visiblePassword, true),
          _field(_root, '根目录 (如 /volume1/duanju)'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存'),
          ),
          if (_saved)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('已保存到本机（local_config.json，不进版本库）',
                  style: TextStyle(color: Colors.green)),
            ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      [TextInputType kb = TextInputType.text, bool obscure = false]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: kb,
        obscureText: obscure,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }
}
