#!/usr/bin/env bash
#
# 构建 → 装到 /Applications → 注册并启用 Finder 扩展 → 重启 Finder。
#
# 用法：
#   ./scripts/install.sh            # Debug（默认，调试用）
#   ./scripts/install.sh Release    # Release
#
# 为什么必须装到 /Applications：
#   Finder 扩展由 PlugInKit 按**路径**注册。同一个 bundle id 存在多份副本时，
#   系统只会认其中一份，而且不保证是哪一份——实测踩过 /Applications 的副本和
#   DerivedData 里的旧副本互相抢注册，pluginkit 里显示成 `!`，扩展时灵时不灵。
#   所以这里每次装完都主动注销其它位置的副本。
#
#   另外从 DerivedData 或 DMG 里直接运行会触发 App Translocation（随机只读路径），
#   导致 TCC 授权失效、扩展注册不稳定。调试期也一样要装到 /Applications。
#
# 改完扩展代码后重跑本脚本即可，不需要手动去系统设置里点来点去。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_ROOT/LXFinderRight.xcodeproj"
SCHEME="LXFinderRight"
CONFIG="${1:-Debug}"
APP_NAME="LXFinderRight"
EXT_ID="com.linx.LXFinderRight.Extension"
# 扩展进程的可执行文件名，用于 pkill。必须和 target 名一致。
EXT_PROCESS="LXFinderRightExtension"
DERIVED="$PROJECT_ROOT/dist-build"
INSTALLED="/Applications/$APP_NAME.app"

# lsregister 在 CoreServices 里，路径几经变动，这里按当前系统的实际位置取。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

if [[ "$CONFIG" != "Debug" && "$CONFIG" != "Release" ]]; then
    echo "❌ 无效配置：$CONFIG（仅支持 Debug / Release）"
    exit 1
fi

echo "🔨 构建 $CONFIG ..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$BUILT" ]] || { echo "❌ 构建产物不存在：$BUILT"; exit 1; }

echo "📦 安装到 /Applications ..."
rm -rf "$INSTALLED"
cp -R "$BUILT" "$INSTALLED"

# 注销其它位置的副本，避免和 /Applications 抢注册。
# 构建产物注册一份就够了，这里连同遗留的 DerivedData 副本一起清。
echo "🧹 注销其它位置的副本 ..."
for stale in "$BUILT" "$HOME"/Library/Developer/Xcode/DerivedData/"$APP_NAME"-*/Build/Products/"$CONFIG"/"$APP_NAME".app; do
    [[ -d "$stale" ]] || continue
    "$LSREGISTER" -u "$stale" 2>/dev/null || true
done

echo "📇 注册并启用扩展 ..."
"$LSREGISTER" -f -R -trusted "$INSTALLED"
pluginkit -e use -i "$EXT_ID" 2>/dev/null || true

echo "🔄 重启 Finder 与扩展进程 ..."
killall Finder 2>/dev/null || true
# **必须单独杀扩展进程**：扩展是 launchd 拉起的独立进程，不是 Finder 的子进程，
# `killall Finder` 不会连带重启它。漏掉这步会拿着旧二进制测新代码——
# 症状极具迷惑性（改动明明编译进去了却毫无效果），实测踩过一次。
pkill -f "$EXT_PROCESS" 2>/dev/null || true
sleep 3

echo ""
echo "🔍 扩展状态："
STATUS="$(pluginkit -mAv -i "$EXT_ID" 2>/dev/null || true)"
if [[ -z "$STATUS" ]]; then
    echo "    ❌ 没有找到扩展注册。检查 $INSTALLED/Contents/PlugIns/ 是否存在。"
    exit 1
fi
echo "$STATUS" | sed 's/^/    /'

# pluginkit 用行首标记状态：`+` 已启用，`-` 已禁用，`!` 注册冲突。
if echo "$STATUS" | grep -q '^+'; then
    echo ""
    echo "✅ 扩展已启用。"
else
    echo ""
    echo "⚠️  扩展未处于「已启用」状态。"
    echo "    手动可去：系统设置 → 通用 → 登录项与扩展 → 文件提供程序"
    echo "    或执行：pluginkit -e use -i $EXT_ID"
fi

# 自检：读扩展自己打的启动日志，确认它真的起来了、而且读到了配置文件。
# 光看 pluginkit 的 `+` 不够——那只说明「注册了」，不说明进程加载的是哪个二进制。
echo ""
echo "🩺 读取扩展自检日志 ..."
CHECK=""
for _ in $(seq 1 10); do
    CHECK="$(/usr/bin/log show --last 40s --info --debug \
        --predicate "process == \"$EXT_PROCESS\"" --style compact 2>/dev/null \
        | grep "自检 · " | tail -3 | sed 's/^.*自检 · /    自检 · /')"
    [[ -n "$CHECK" ]] && break
    sleep 1
done

if [[ -n "$CHECK" ]]; then
    echo "$CHECK"
else
    echo "    （扩展还没被 Finder 拉起。去任意文件夹空白处右键一次，然后重跑本步：）"
    echo "    /usr/bin/log show --last 1m --info --debug --predicate 'process == \"$EXT_PROCESS\"' | grep 自检"
fi
echo ""
echo "提示：日志命令要用 /usr/bin/log，zsh 有个同名内建命令会把 'log stream' 吃掉。"
