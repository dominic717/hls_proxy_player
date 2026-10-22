/// tv_keys.dart — 单一来源: 电视遥控器"确认/OK"键的多种映射。
///
/// 之前 main.dart / target_player.dart / ftp_catalog_page.dart 各自重复定义了
/// _tvOkKeyId + _isActivate / _isActivateKey, 且 key 集合不一致 (main 的 _DramaCard
/// 内联版漏了 space + gameButtonA, 导致部分遥控器在主目录卡片上按 OK 无反应,
/// 而播放器/FTP 页却正常 — 不一致是 bug 温床)。
///
/// 现统一在此一处维护, 三个文件都 import 用 isTvActivateKey()。
library;

import 'package:flutter/services.dart';

/// 部分国产电视 (VIDAA / Amlogic) 把 OK 键映射成未登记的逻辑键
/// (实测 keyId = 0x10000050c), 而非标准 LogicalKeyboardKey.select。
/// 遥控器激活键必须一并放行, 否则焦点在按钮/卡片上按 OK 无反应。
const int kTvOkKeyId = 0x10000050c;

/// 遥控器"确认/OK"键的多种映射: 标准 TV/手机 + 部分国产电视自定义键。
/// 这是全代码库唯一的判定函数 — 加新键只改这里一处。
///
/// 覆盖的键:
///   - select (标准 TV OK)
///   - enter / numpadEnter (键盘 Enter)
///   - space (空格 — 手机/部分遥控也作确认)
///   - gameButtonA (游戏手柄 A)
///   - 0x10000050c (VIDAA/Amlogic 自定义 OK 键)
bool isTvActivateKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.space ||
    k == LogicalKeyboardKey.gameButtonA ||
    k.keyId == kTvOkKeyId;
