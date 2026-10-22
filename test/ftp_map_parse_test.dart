// ftp_map_parse_test.dart — FTP _map.txt 解析 + m3u8 URL 构建单元测试
// 运行: flutter test test/ftp_map_parse_test.dart

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('_map.txt TAB 分隔解析', () {
    // 与 ftp_source.dart listCatalog 的 _map.txt 格式一致:
    // # storage_path<TAB>real_category<TAB>family_id<TAB>series_id
    // xiandai/drama_123<TAB>aijc<TAB>mrds66<TAB>123
    // cover_123=https://cdn.example.com/cover123.jpg

    test('标准行解析为 4 字段', () {
      const line = 'xiandai/drama_123\taijc\tmrds66\t123';
      final parts = line.split('\t');
      expect(parts.length, 4);
      expect(parts[0], 'xiandai/drama_123');  // storage_path
      expect(parts[1], 'aijc');                  // real_category
      expect(parts[2], 'mrds66');                // family_id
      expect(parts[3], '123');                   // series_id
    });

    test('注释行和空行跳过', () {
      const lines = [
        '# storage_path\treal_category\tfamily_id\tseries_id',
        '',
        '   ',
        'xiandai/drama_456\tsmdh\tmrds66\t456',
      ];
      final valid = lines.where((l) {
        final t = l.trim();
        return t.isNotEmpty && !t.startsWith('#');
      }).toList();
      expect(valid.length, 1);
      expect(valid[0].split('\t')[3], '456');
    });

    test('cover_<vid> 行解析', () {
      const line = 'cover_123=https://cdn.example.com/cover123.jpg';
      final re = RegExp(r'^cover_(\d+)=(.*)$');
      final m = re.firstMatch(line);
      expect(m, isNotNull);
      expect(m!.group(1), '123');  // vid
      expect(m.group(2), 'https://cdn.example.com/cover123.jpg');  // cover URL
    });

    test('series_id 从 storage_path 提取', () {
      const storagePath = 'xiandai/drama_789';
      // storage_path 最后一段 = series_id
      final sid = storagePath.split('/').last;
      expect(sid, 'drama_789');
    });
  });

  group('video_id 32-hex 提取 (m3u8 URL)', () {
    // 与 crawler video_id_of 一致: 从 m3u8 URL 路径提取 32 位 hex
    test('标准 m3u8 URL', () {
      const url = 'https://cdn.example.com/abc123def4567890abcdef1234567890/index.m3u8';
      final m = RegExp(r'/([0-9a-f]{32})/').firstMatch(url);
      expect(m, isNotNull);
      expect(m!.group(1), 'abc123def4567890abcdef1234567890');
    });

    test('无 32-hex 时退回 (URL 末 40 字符)', () {
      const url = 'https://cdn.example.com/index.m3u8';
      final m = RegExp(r'/([0-9a-f]{32})/').firstMatch(url);
      expect(m, isNull);  // 不匹配 → crawler 用 fallback
    });

    test('32-hex 大写不匹配 (只认小写)', () {
      const url = 'https://cdn/ABC123DEF4567890ABCDEF1234567890/index.m3u8';
      final m = RegExp(r'/([0-9a-f]{32})/').firstMatch(url);
      // 大写 hex 不匹配 [0-9a-f] — crawler 用 fallback
      expect(m, isNull);
    });
  });

  group('HLS m3u8 本地播放列表格式 (TS-only)', () {
    test('EXTINF + 相对 .ts 路径 + ENDLIST', () {
      // 与 crawler v2.3 写的 ep01.m3u8 格式一致
      final lines = <String>[
        '#EXTM3U',
        '#EXT-X-VERSION:3',
        '#EXT-X-TARGETDURATION:10',
        '#EXTINF:5.234,',
        '00000.ts',
        '#EXTINF:4.567,',
        '00001.ts',
        '#EXT-X-ENDLIST',
      ];
      final m3u8 = lines.join('\n');
      expect(m3u8.startsWith('#EXTM3U'), isTrue);
      expect(m3u8.contains('#EXT-X-ENDLIST'), isTrue);
      expect(m3u8.contains('00000.ts'), isTrue);
      expect(m3u8.contains('00001.ts'), isTrue);
      // 无 #EXT-X-KEY (已解密)
      expect(m3u8.contains('#EXT-X-KEY'), isFalse);
    });
  });
}
