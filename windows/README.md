# nape-hud (Windows CLI)

Keychron Nape Pro の **レイヤー / OctaShift の向き / DPI** を Windows のコンソールで
検出・表示する CLI 版です。macOS 版と**同じ `config.json`** を読みます。

> GUI（ポップアップ・メニューバー・設定画面）は含みません。
> 状態の変化を標準出力に 1 行ずつ出します。

## インストール

インストール作業はありません。Release から落として好きな場所に置くだけです。
管理者権限もレジストリ変更も不要で、消すときはファイルを削除するだけです。

| PC | ファイル | .NET |
|---|---|---|
| ふつうの Windows 10/11 | `nape-hud-<ver>-win-x64.zip` | 不要 |
| ARM 版 Windows | `nape-hud-<ver>-win-arm64.zip` | 不要 |
| 32bit Windows | `nape-hud-<ver>-win-x86.zip` | 不要 |
| 誤検知・実行制限を避けたい | `nape-hud-<ver>-dotnet.zip`（80KB） | ランタイム 10 が必要 |

exe は**コード署名していない**ので SmartScreen が警告します。「詳細情報」→「実行」、
または `Unblock-File .\nape-hud.exe`。`SHA256SUMS.txt` でハッシュを照合できます。

止まって動かせない場合の対処は **[INSTALL.md](INSTALL.md)** に症状別でまとめています
（SmartScreen / ウイルス対策ソフトの誤検知 / CPU 種別の不一致 / 組織のポリシーで
exe が使えない場合 / 文字化け / ログオン時の自動起動）。

## 使い方

```
nape-hud devices     接続中の HID デバイスを列挙し、照合結果と不一致の理由を出す
nape-hud run         状態の変化を出力し続ける（Ctrl-C で終了）
nape-hud sniff       生の HID レポートを観測する
nape-hud keymap      デバイスに登録されたキーアサインを読み出す（VIA プロトコル）
nape-hud selftest    合成レポートで復号経路を検証する（デバイス不要）
```

オプション: `-c <path>` 設定ファイル / `-s <秒>` 観測秒数（既定 90、0 で無制限）/ `-v` 詳細

まず `nape-hud devices` を実行してください。検出できる経路かどうかを判定します。

`run` の出力例:

```
[21:03:41] Layer 2  Layer 2      （Layer 2 · 180° · 1600 DPI）
[21:03:44] OctaShift  225°       （Layer 2 · 225° · 1600 DPI）
[21:03:47] DPI  2400 DPI         （Layer 2 · 225° · 2400 DPI）
```

## 設定ファイル

探索順:

1. `-c` で指定したパス
2. `%APPDATA%\nape-hud\config.json`
3. 実行ファイルと同じ場所の `config.json`
4. どこにも無ければ**実行ファイルに内蔵した既定値**

4 のおかげで `nape-hud.exe` 単体でも動きますが、OctaShift の 0° の基準は
個体ごとの校正結果なので、macOS 版を使っているなら
`~/.config/nape-hud/config.json` をコピーするのが確実です。

CLI 版が読むのは `device` / `rules` / `layerNames` / `angleNames` / `dpiNames` /
`keymap` / `hud.layerNumberOffset` だけです。ポインタ加速・HUD の見た目・
キャリブレーションに関する項目は無視されます
（`learn` と `calibrate` は macOS 版のみ。角度の対応表は `angleNames` を直接編集してください）。

## 対応している接続方式

macOS 版と同じ制約があります。

| 接続 | 検出 |
|---|---|
| USB 有線 | ✅ |
| 2.4GHz ドングル | ✅（`Keychron Link-KM` / PID `0xD026` として現れる） |
| Bluetooth | ❌ ベンダ面 `0xFF60` が出ないため検出不可 |

Bluetooth が使えないのはファームウェア側の制約です。BLE のレポート記述子に
ベンダ面が宣言されておらず（申告されるのは `0x0001/0x0007/0x0008/0x0009/0x000C` のみ）、
状態通知 `0xA3 …` を運ぶ経路が存在しません。OS を変えても解決しません。

## ソースからビルドする

macOS / Linux からでも Windows 向けにビルドできます（.NET SDK 10 以上）。

```sh
cd windows/NapeHudCli
dotnet publish -c Release -o ../dist
```

`../dist/nape-hud.exe` ができます。

配布物一式（3 アーキテクチャ + ランタイム依存版 + `SHA256SUMS.txt`）は
`windows/make-dist.sh` でまとめて作れます。

## 検証状況

- 復号ロジック（レイヤー / 向き / DPI の優先順位）は `selftest` で macOS 版と
  出力が一致することを確認済み。同じ `config.json` を読ませて突き合わせています。
- HID アクセス部分（SetupAPI / hid.dll の P/Invoke）は**実機の Windows で未検証**です。
  開発機が macOS のため実行できていません。`devices` → `sniff` → `run` の順に
  試して、うまくいかない場合は出力を添えて issue を立ててください。
