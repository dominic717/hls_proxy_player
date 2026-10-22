/// 共用 AES-128-CBC 解密工具（通用，不绑定任何特定站点）。
/// 仅保留通用的「字节密钥」解密，供合法自有/标准 HLS 内容的 AES-128 分段解密使用。
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

class CryptoUtil {
  /// 裸 CBC 逐块解密（数据须 16 对齐），密钥/IV 以字节形式传入。
  static Uint8List cbcDecrypt(List<int> data, String key, String iv) {
    final cbc = pc.CBCBlockCipher(pc.AESEngine())
      ..init(
          false,
          pc.ParametersWithIV(
              pc.KeyParameter(Uint8List.fromList(key.codeUnits)),
              Uint8List.fromList(iv.codeUnits)));
    final src = data is Uint8List ? data : Uint8List.fromList(data);
    final out = Uint8List(data.length);
    for (var off = 0; off + 16 <= data.length; off += 16) {
      cbc.processBlock(src, off, out, off);
    }
    return out;
  }

  /// 字节版密钥解密（HLS 标准 AES-128 分片用：密钥来自 m3u8 的 #EXT-X-KEY，随内容下发）
  static Uint8List cbcDecryptBytes(List<int> data, List<int> key, List<int> iv) {
    final cbc = pc.CBCBlockCipher(pc.AESEngine())
      ..init(false, pc.ParametersWithIV(pc.KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv)));
    final src = data is Uint8List ? data : Uint8List.fromList(data);
    final out = Uint8List(data.length);
    for (var off = 0; off + 16 <= data.length; off += 16) {
      cbc.processBlock(src, off, out, off);
    }
    return out;
  }
}
