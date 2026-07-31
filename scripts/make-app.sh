#!/bin/bash
# NapeHUD.app を組み立てる。
#
#   ./scripts/make-app.sh                 … build/NapeHUD.app を作る
#   ./scripts/make-app.sh --install       … 作って /Applications へ配置する
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/make-app.sh
#
# 署名について:
#   既定は ad-hoc 署名（自己署名なし）。動作はするが、再ビルドで署名が変わると
#   アクセシビリティ等の許可が外れて再許可を求められることがある。
#   Developer ID を持っている場合は CODESIGN_IDENTITY で指定すると安定する。

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="NapeHUD"
BUNDLE_ID="com.local.nape-hud"
VERSION="1.0.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> リリースビルド"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "実行ファイルが見つかりません: $BIN" >&2; exit 1; }

echo "==> バンドルを作成"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "==> アイコンを生成"
if ! swift "$ROOT/scripts/make-icon.swift" "$APP/Contents/Resources/$APP_NAME.icns"; then
    echo "   アイコン生成に失敗したのでアイコン無しで続行します" >&2
    ICON_ENTRY=""
else
    ICON_ENTRY="	<key>CFBundleIconFile</key>
	<string>$APP_NAME</string>"
fi

echo "==> Info.plist を書き出し"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>nape-hud</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
$ICON_ENTRY
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Dock にもアプリスイッチャーにも出さない常駐アプリ。操作はメニューバーから -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- 権限ダイアログに出る説明文。理由が分かる文言にしておく -->
	<key>NSInputMonitoringUsageDescription</key>
	<string>Keychron Nape Pro のレイヤー・向き・DPI の切替を検出するために、キーボード面の HID レポートを読み取ります。</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>設定ファイルを開くために Finder を呼び出します。</string>
</dict>
</plist>
PLIST

echo "==> 署名 (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" --timestamp=none \
    --identifier "$BUNDLE_ID" \
    "$APP/Contents/MacOS/$APP_NAME" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp=none \
    --identifier "$BUNDLE_ID" \
    "$APP" >/dev/null
codesign --verify --deep --strict "$APP" && echo "   署名を検証しました"

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> $DEST へ配置"
    # 実行中なら止めてから差し替える
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    APP="$DEST"
fi

echo ""
echo "完成: $APP"
echo ""
echo "起動      : open \"$APP\""
echo "CLI 利用  : \"$APP/Contents/MacOS/$APP_NAME\" doctor"
echo "ログイン時: システム設定 → 一般 → ログイン項目 に上記アプリを追加"
