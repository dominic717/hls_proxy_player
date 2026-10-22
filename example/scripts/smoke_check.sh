#!/bin/bash
# 冒烟检查：装机启动后自动检查常见低级故障（null URL、未捕获异常、播放停滞）
# 用法: ./scripts/smoke_check.sh [包名] [等待秒数]
PKG=${1:-com.example.hls_web_player}
WAIT=${2:-40}
ADB=$(which adb || echo /Users/zhang/android-sdk/platform-tools/adb)

"$ADB" logcat -c
"$ADB" shell am force-stop "$PKG"
"$ADB" shell am start -n "$PKG/.MainActivity"
sleep "$WAIT"
"$ADB" logcat -d -s flutter > /tmp/smoke.log

FAIL=0
if grep -q 'null/' /tmp/smoke.log; then
  echo "❌ 出现 null/ URL（代理未启动等装配错误）"; FAIL=1
fi
if grep -q 'E flutter' /tmp/smoke.log; then
  echo "❌ 存在未捕获异常"; grep 'E flutter' /tmp/smoke.log | head -5; FAIL=1
fi
# 播放位置应随时间增长（若出现 [断点] 保存）
LAST=$(grep '\[断点\] 保存' /tmp/smoke.log | tail -1)
FIRST=$(grep '\[断点\] 保存' /tmp/smoke.log | head -1)
if [ -n "$LAST" ] && [ "$FIRST" == "$LAST" ]; then
  echo "⚠️ 播放位置未增长（可能暂停/卡住）: $LAST"
fi
[ $FAIL -eq 0 ] && echo "✅ 冒烟检查通过"
exit $FAIL
