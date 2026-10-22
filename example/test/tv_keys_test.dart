// tv_keys_test.dart — TV 遥控器 OK 键判定单元测试
// 运行: flutter test test/tv_keys_test.dart

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hls_proxy_player_example/tv_keys.dart';

void main() {
  group('isTvActivateKey', () {
    test('标准 TV/手机键全部识别为激活', () {
      expect(isTvActivateKey(LogicalKeyboardKey.select), isTrue);
      expect(isTvActivateKey(LogicalKeyboardKey.enter), isTrue);
      expect(isTvActivateKey(LogicalKeyboardKey.numpadEnter), isTrue);
      expect(isTvActivateKey(LogicalKeyboardKey.space), isTrue);
      expect(isTvActivateKey(LogicalKeyboardKey.gameButtonA), isTrue);
    });

    test('VIDAA/Amlogic 自定义 OK 键 (0x10000050c) 识别为激活', () {
      // 构造 keyId=0x10000050c 的键 — 部分国产电视把 OK 映射成这个未登记键
      const tvOk = LogicalKeyboardKey(kTvOkKeyId);
      expect(isTvActivateKey(tvOk), isTrue);
    });

    test('方向键/数字键/字母键不识别为激活', () {
      expect(isTvActivateKey(LogicalKeyboardKey.arrowUp), isFalse);
      expect(isTvActivateKey(LogicalKeyboardKey.arrowDown), isFalse);
      expect(isTvActivateKey(LogicalKeyboardKey.arrowLeft), isFalse);
      expect(isTvActivateKey(LogicalKeyboardKey.arrowRight), isFalse);
      expect(isTvActivateKey(LogicalKeyboardKey.backspace), isFalse);
      expect(isTvActivateKey(LogicalKeyboardKey.keyA), isFalse);
      expect(isTvActivateKey(LogicalKeyboardKey.digit1), isFalse);
    });

    test('kTvOkKeyId 常量值正确', () {
      expect(kTvOkKeyId, equals(0x10000050c));
    });
  });
}
