#!/usr/bin/env bash
#
# 打包发布产物：Release 构建 → 复制到 dist-free/ → 校验闸门 → zip + dmg。
#
# 用法：
#   ./scripts/distribute-free.sh
#
# 本脚本**不签名、不公证**，产物会带 Gatekeeper 警告（用户需右键「打开」）。
# 这与 LXFinderLauncher 的免费分发方式一致，是当前团队的分发惯例。
#
# 校验闸门是这里的重点。任何一项不过就中止发布，绝不产出半成品包——
# 这个项目踩过「签名证书被吊销却没发现，导致所有授权反复弹窗」的坑，
# 那次代价很大，所以宁可在这里拦住。

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_ROOT/LXFinderRight.xcodeproj"
SCHEME="LXFinderRight"
CONFIG="Release"
APP_NAME="LXFinderRight"
DIST="$PROJECT_ROOT/dist-free"
DERIVED="$PROJECT_ROOT/dist-build"
APPEX_NAME="LXFinderRightExtension.appex"

echo "🔨 构建 $CONFIG ..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

APP_SRC="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$APP_SRC" ]] || { echo "❌ 构建产物不存在：$APP_SRC"; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP_SRC" "$DIST/$APP_NAME.app"
APP="$DIST/$APP_NAME.app"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
echo "📦 产物版本：$VERSION ($BUILD)"

# ---------------------------------------------------------------
# 校验闸门
# ---------------------------------------------------------------
# 取签名证书名（第一行 Authority）。
#
# 不要写成 `codesign -dvvv ... | grep -m1 '^Authority='`：`grep -m1` / `head -1`
# 会在读到第一行后提前关闭管道，codesign 收到 SIGPIPE 而死；在 `set -o pipefail` 下
# 整条管道被判定为失败，`|| 兜底` 就会误触发，值里多出一行垃圾。
# 这里先整体捕获输出，再用不提前退出的 sed 取第一行。
sign_authority() {
    local out
    out="$(codesign -dvvv "$1" 2>&1 || true)"
    printf '%s\n' "$out" | sed -n 's/^Authority=//p' | sed -n '1p'
}

echo "🔏 校验签名 ..."
SIGN_ERROR="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)" || {
    echo "❌ 签名校验失败，已中止打包："
    echo "$SIGN_ERROR" | sed 's/^/    /'
    echo ""
    if echo "$SIGN_ERROR" | grep -q "CSSMERR_TP_CERT_REVOKED"; then
        echo "原因：签名用的开发证书已被吊销。"
        echo "处理：Xcode → Settings → Accounts → Manage Certificates，"
        echo "      删掉吊销/过期的 Apple Development 证书，重新签一张，再跑本脚本。"
    fi
    exit 1
}
SIGN_CERT="$(sign_authority "$APP")"
echo "    ✅ 签名有效：$SIGN_CERT"

# 嵌在里面的扩展必须存在、且和宿主用同一张证书签。
# 不一致的话 --deep 校验有时仍会通过，但用户装上去扩展根本不会加载，
# 症状是「菜单不出现」，极难排查——所以在这里单独确认一遍。
echo "🔏 校验内嵌扩展 ..."
APPEX="$APP/Contents/PlugIns/$APPEX_NAME"
if [[ ! -d "$APPEX" ]]; then
    echo "❌ 扩展没有被内嵌进 App：$APPEX 不存在"
    exit 1
fi
APPEX_CERT="$(sign_authority "$APPEX")"
if [[ "$APPEX_CERT" != "$SIGN_CERT" ]]; then
    echo "❌ 扩展与宿主的签名证书不一致，会导致扩展无法加载："
    echo "    宿主：$SIGN_CERT"
    echo "    扩展：$APPEX_CERT"
    exit 1
fi
echo "    ✅ 与宿主同证书"

# 宿主与扩展的版本号必须一致，否则校验/公证会失败。
APPEX_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APPEX/Contents/Info.plist")"
APPEX_BUILD="$(plutil -extract CFBundleVersion raw "$APPEX/Contents/Info.plist")"
if [[ "$APPEX_VERSION" != "$VERSION" || "$APPEX_BUILD" != "$BUILD" ]]; then
    echo "❌ 宿主与扩展的版本号不一致："
    echo "    宿主：$VERSION ($BUILD)"
    echo "    扩展：$APPEX_VERSION ($APPEX_BUILD)"
    exit 1
fi
echo "    ✅ 版本号一致：$APPEX_VERSION ($APPEX_BUILD)"

# 带 provisioning profile 说明用了「能力」（capability），而自动签名给的是
# 开发用 profile——绑定设备 UUID 且 7 天过期，发出去别人装不上、很快也会失效。
# 当前方案刻意不使用任何 capability，所以这里必须看到「没有 profile」。
if find "$APP" -name "*.provisionprofile" | grep -q .; then
    echo "❌ 产物里带了 provisioning profile："
    find "$APP" -name "*.provisionprofile" | sed 's/^/    /'
    echo "   这通常意味着引入了 App Group / iCloud 之类的 capability，"
    echo "   开发用 profile 会绑定本机设备且很快过期，不适合公开分发。"
    exit 1
fi
echo "    ✅ 无 provisioning profile（不需要任何 capability）"

# Debug 产物带的薄壳 dylib 不能进分发包。
if find "$APP" -name "*.debug.dylib" | grep -q .; then
    echo "❌ 产物里含 debug.dylib，说明这不是有效合并的 Release 构建。"
    exit 1
fi
echo "    ✅ 无 debug 薄壳"

# ---------------------------------------------------------------
# 打包
# ---------------------------------------------------------------
echo "🗜  打包 ..."
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME.zip"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null

echo ""
echo "✅ 完成，产物在 dist-free/："
ls -lh "$DIST" | tail -n +2 | awk '{printf "    %-28s %s\n", $9, $5}'
echo ""
echo "提示：本包未公证，用户首次打开需右键 →「打开」绕过 Gatekeeper。"
