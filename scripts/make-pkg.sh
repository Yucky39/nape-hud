#!/bin/bash
# インストーラ (.pkg) を作る。ダブルクリックで /Applications へ入る。
#
#   ./scripts/make-pkg.sh
#   PKG_SIGN_IDENTITY="Developer ID Installer: ..." ./scripts/make-pkg.sh
#
# 署名について:
#   既定は未署名。未署名の pkg は Gatekeeper が警告を出すので、初回は
#   右クリック →「開く」で進める必要がある（README の手順を参照）。
#   Developer ID Installer 証明書があれば PKG_SIGN_IDENTITY で署名できる。

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="NapeHUD"
BUNDLE_ID="com.local.nape-hud"
# アプリ側とバージョンがずれないよう make-app.sh から拾う
VERSION="$(grep -m1 '^VERSION=' scripts/make-app.sh | cut -d'"' -f2)"
OUT_DIR="$ROOT/build"
PKG="$OUT_DIR/$APP_NAME-$VERSION.pkg"
WORK="$OUT_DIR/pkg-work"

echo "==> アプリを組み立て"
./scripts/make-app.sh >/dev/null
APP="$OUT_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "アプリが見つかりません: $APP" >&2; exit 1; }

echo "==> ペイロードを用意"
rm -rf "$WORK"
mkdir -p "$WORK/root/Applications" "$WORK/scripts"
# バンドルのコピーは ditto を使う（cp -R だと拡張属性が ._* として payload に混入する）
ditto "$APP" "$WORK/root/Applications/$APP_NAME.app"
# provenance などの拡張属性も落としておく
xattr -cr "$WORK/root/Applications/$APP_NAME.app" 2>/dev/null || true
find "$WORK/root" -name '.DS_Store' -delete 2>/dev/null || true

# 設定ファイルの雛形を同梱し、postinstall から利用者のホームへ配置する
cp "$ROOT/config.example.json" "$WORK/scripts/config.example.json"

echo "==> インストールスクリプトを用意"

# 稼働中だとバンドルを差し替えられないので先に止める
cat > "$WORK/scripts/preinstall" <<'PRE'
#!/bin/bash
# 実行中のアプリを終了させる（失敗しても続行）
pkill -x NapeHUD 2>/dev/null || true
exit 0
PRE

cat > "$WORK/scripts/postinstall" <<'POST'
#!/bin/bash
# postinstall は root で動くので、$HOME は利用者のものではない。
# コンソールにログインしている利用者を調べて、その人のホームへ設定を置く。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

USER_NAME="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
    echo "ログイン中の利用者を特定できないため、設定配置と起動をスキップします"
    exit 0
fi
USER_UID="$(/usr/bin/id -u "$USER_NAME")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
[ -n "$USER_HOME" ] || USER_HOME="/Users/$USER_NAME"

CONF_DIR="$USER_HOME/.config/nape-hud"
CONF="$CONF_DIR/config.json"

/bin/mkdir -p "$CONF_DIR"
# 雛形は常に置く（更新版の参照用）
/bin/cp "$HERE/config.example.json" "$CONF_DIR/config.example.json"
if [ -f "$CONF" ]; then
    # 既存の設定は上書きしない。校正結果や DPI 値の書き換えが入っているため。
    echo "既存の設定を残しました: $CONF"
else
    /bin/cp "$HERE/config.example.json" "$CONF"
    echo "設定を配置しました: $CONF"
fi
# root で作ったものを利用者の所有に直す（作った範囲だけ）
/usr/sbin/chown "$USER_NAME" "$USER_HOME/.config" 2>/dev/null || true
/usr/sbin/chown -R "$USER_NAME" "$CONF_DIR" 2>/dev/null || true

# 利用者のセッションでアプリを起動する
/bin/launchctl asuser "$USER_UID" /usr/bin/open -a "/Applications/NapeHUD.app" 2>/dev/null || true
exit 0
POST

chmod +x "$WORK/scripts/preinstall" "$WORK/scripts/postinstall"
# 構文エラーのあるスクリプトを詰めてしまうとインストール時に初めて失敗するので、ここで検査する
bash -n "$WORK/scripts/preinstall"
bash -n "$WORK/scripts/postinstall"
echo "   スクリプトの構文を検査しました"

echo "==> pkg を作成"
mkdir -p "$OUT_DIR"
rm -f "$PKG"
PKGBUILD_ARGS=(
    --root "$WORK/root"
    --scripts "$WORK/scripts"
    --identifier "$BUNDLE_ID"
    --version "$VERSION"
    --install-location /
)
if [ -n "${PKG_SIGN_IDENTITY:-}" ]; then
    PKGBUILD_ARGS+=(--sign "$PKG_SIGN_IDENTITY")
    echo "   署名: $PKG_SIGN_IDENTITY"
else
    echo "   署名: なし（初回は右クリック →「開く」で実行してください）"
fi
pkgbuild "${PKGBUILD_ARGS[@]}" "$PKG" >/dev/null

rm -rf "$WORK"

echo ""
echo "完成: $PKG"
echo "  サイズ: $(du -h "$PKG" | cut -f1)"
echo ""
echo "インストール:"
echo "  ダブルクリック（初回は右クリック →「開く」）"
echo "  または: sudo installer -pkg \"$PKG\" -target /"
echo ""
echo "インストール内容:"
echo "  /Applications/NapeHUD.app"
echo "  ~/.config/nape-hud/config.json （無い場合のみ作成。既存は温存）"
echo "  インストール後に自動起動します"
