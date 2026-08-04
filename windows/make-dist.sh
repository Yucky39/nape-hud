#!/bin/bash
# Windows 版の配布物をまとめて作る。macOS / Linux からでも実行できる。
#
# 生成物（windows/dist/ 以下）:
#   nape-hud-<ver>-win-x64.zip        CLI・通常の 64bit Windows 向け
#   nape-hud-<ver>-win-arm64.zip      CLI・ARM 版 Windows 向け
#   nape-hud-<ver>-win-x86.zip        CLI・32bit Windows 向け
#   nape-hud-<ver>-dotnet.zip         CLI・.NET 10 導入済み環境向け（数十 KB）
#   nape-hud-gui-<ver>-win-x64.zip    GUI・常駐してポップアップを出す版
#   nape-hud-gui-<ver>-dotnet.zip     GUI・.NET 10 導入済み環境向け（小さい）
#   SHA256SUMS.txt                    改ざん・破損の検証用
#
# exe が AV に消される / SmartScreen で止まる / 実行ファイルの
# ダウンロードが禁止されている環境向けに、zip と小さい版も用意している。
#
# GUI を単一ファイルにはしない。macOS 上でのバンドル生成が WinForms の
# ファイル集合で失敗するため（GenerateBundle が落ちる）、フォルダ配布にする。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
CLI="NapeHudCli"
GUI="NapeHudGui"
DIST="dist"
VERSION="$(grep -m1 '^VERSION=' "$ROOT/scripts/make-app.sh" | cut -d'"' -f2)"

command -v dotnet >/dev/null || { echo "dotnet が見つかりません。.NET SDK 10 以上を入れてください。" >&2; exit 1; }

echo "nape-hud (Windows) $VERSION の配布物を作ります"
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
  dotnet publish "$CLI" -c Release -r "$rid" -o "$DIST/$rid" --nologo -v q >/dev/null
  rm -f "$DIST/$rid"/*.pdb
  pack "nape-hud-$VERSION-$rid.zip" "$DIST/$rid"
done

echo "ビルド: CLI・ランタイム依存（.NET 10 が入っている環境向け）"
dotnet publish "$CLI" -c Release -o "$DIST/dotnet" --nologo -v q \
  -p:SelfContained=false -p:PublishSingleFile=false \
  -p:RuntimeIdentifier= -p:EnableCompressionInSingleFile=false >/dev/null
# RID を外すとビルドした OS 用の起動役ができるが Windows では使わない。
# Windows では `dotnet nape-hud.dll` で起動する。
rm -f "$DIST/dotnet"/*.pdb "$DIST/dotnet/nape-hud" "$DIST/dotnet/nape-hud.exe"
pack "nape-hud-$VERSION-dotnet.zip" "$DIST/dotnet"

echo "ビルド: GUI・win-x64（ランタイム同梱・フォルダ）"
dotnet publish "$GUI" -c Release -o "$DIST/gui-win-x64" --nologo -v q >/dev/null
rm -f "$DIST/gui-win-x64"/*.pdb
pack "nape-hud-gui-$VERSION-win-x64.zip" "$DIST/gui-win-x64"

echo "ビルド: GUI・ランタイム依存（.NET 10 デスクトップランタイムが必要）"
dotnet publish "$GUI" -c Release -o "$DIST/gui-dotnet" --nologo -v q \
  -p:SelfContained=false -p:RuntimeIdentifier= >/dev/null
rm -f "$DIST/gui-dotnet"/*.pdb "$DIST/gui-dotnet/nape-hud-gui"
pack "nape-hud-gui-$VERSION-dotnet.zip" "$DIST/gui-dotnet"

# 単体で置きたい人向けに x64 の CLI exe もそのまま出す
cp "$DIST/win-x64/nape-hud.exe" "$DIST/nape-hud.exe"

(cd "$DIST" && shasum -a 256 nape-hud.exe ./*.zip | sed 's| \./| |' > SHA256SUMS.txt)

echo
echo "完成: $PWD/$DIST"
ls -1 "$DIST" | grep -E '\.(zip|exe|txt)$' | sed 's/^/  /'
echo
echo "検証（Windows 側・PowerShell）:"
echo '  Get-FileHash .\nape-hud.exe -Algorithm SHA256'
