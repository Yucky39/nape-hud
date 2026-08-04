#!/bin/bash
# Windows CLI の配布物をまとめて作る。macOS / Linux からでも実行できる。
#
# 生成物（windows/dist/ 以下）:
#   nape-hud-<ver>-win-x64.zip      通常の 64bit Windows 向け
#   nape-hud-<ver>-win-arm64.zip    ARM 版 Windows 向け（Snapdragon 機など）
#   nape-hud-<ver>-win-x86.zip      32bit Windows 向け
#   nape-hud-<ver>-dotnet.zip       .NET 10 導入済み環境向け（数百 KB）
#   SHA256SUMS.txt                  改ざん・破損の検証用
#
# exe が AV に消される / SmartScreen で止まる / 実行ファイルの
# ダウンロードが禁止されている環境向けに、zip と小さい版も用意している。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
PROJ="NapeHudCli"
DIST="dist"
VERSION="$(grep -m1 '^VERSION=' "$ROOT/scripts/make-app.sh" | cut -d'"' -f2)"

command -v dotnet >/dev/null || { echo "dotnet が見つかりません。.NET SDK 10 以上を入れてください。" >&2; exit 1; }

echo "nape-hud (Windows CLI) $VERSION の配布物を作ります"
rm -rf "$DIST"
mkdir -p "$DIST"

pack() {   # pack <zip 名> <元ディレクトリ>
  local name="$1" src="$2"
  cp "$ROOT/config.example.json" "$src/config.json"
  cp README.md "$src/README.md"
  (cd "$src" && zip -qr "../$name" .)
  echo "  $name"
}

for rid in win-x64 win-arm64 win-x86; do
  echo "ビルド: ${rid}（ランタイム同梱・単一ファイル）"
  dotnet publish "$PROJ" -c Release -r "$rid" -o "$DIST/$rid" --nologo -v q >/dev/null
  rm -f "$DIST/$rid"/*.pdb
  pack "nape-hud-$VERSION-$rid.zip" "$DIST/$rid"
done

echo "ビルド: ランタイム依存（.NET 10 が入っている環境向け）"
dotnet publish "$PROJ" -c Release -o "$DIST/dotnet" --nologo -v q \
  -p:SelfContained=false -p:PublishSingleFile=false \
  -p:RuntimeIdentifier= -p:EnableCompressionInSingleFile=false >/dev/null
# RID を外すとビルドした OS 用の起動役ができるが Windows では使わない。
# Windows では `dotnet nape-hud.dll` で起動する。
rm -f "$DIST/dotnet"/*.pdb "$DIST/dotnet/nape-hud" "$DIST/dotnet/nape-hud.exe"
pack "nape-hud-$VERSION-dotnet.zip" "$DIST/dotnet"

# 単体で置きたい人向けに x64 の exe もそのまま出す
cp "$DIST/win-x64/nape-hud.exe" "$DIST/nape-hud.exe"

(cd "$DIST" && shasum -a 256 nape-hud.exe ./*.zip | sed 's| \./| |' > SHA256SUMS.txt)

echo
echo "完成: $PWD/$DIST"
ls -1 "$DIST" | grep -E '\.(zip|exe|txt)$' | sed 's/^/  /'
echo
echo "検証（Windows 側・PowerShell）:"
echo '  Get-FileHash .\nape-hud.exe -Algorithm SHA256'
