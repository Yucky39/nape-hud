# nape-hud (Windows)

Keychron Nape Pro の **レイヤー / OctaShift の向き / DPI** を Windows で検出して
表示します。macOS 版と**同じ `config.json`・同じ復号コード**を使います。

2 つの形があります。どちらか片方でも、両方入れても構いません。

| | 何をするか |
|---|---|
| **GUI** `nape-hud-gui.exe` | 通知領域に常駐し、切り替わったら画面の隅にポップアップを出す |
| **CLI** `nape-hud.exe` | 状態の変化をコンソールに 1 行ずつ出す。診断用の機能もこちら |

## インストール

インストール作業はありません。Release から落として好きな場所に置くだけです。
管理者権限もレジストリ変更も不要で、消すときはファイルを削除するだけです。

**GUI**

| PC | ファイル | .NET |
|---|---|---|
| ふつうの Windows 10/11 | `nape-hud-gui-<ver>-win-x64.zip` | 不要 |
| 誤検知・実行制限を避けたい | `nape-hud-gui-<ver>-dotnet.zip`（56KB） | デスクトップランタイム 10 が必要 |

GUI はフォルダ配布です（単一ファイルにはできません。理由は「ソースからビルドする」に記載）。
展開したフォルダごと置いて、中の `nape-hud-gui.exe` を実行してください。
ARM 版 / 32bit Windows は x64 版がエミュレーションで動きます。

**CLI**

| PC | ファイル | .NET |
|---|---|---|
| ふつうの Windows 10/11 | `nape-hud-<ver>-win-x64.zip` | 不要 |
| ARM 版 Windows | `nape-hud-<ver>-win-arm64.zip` | 不要 |
| 32bit Windows | `nape-hud-<ver>-win-x86.zip` | 不要 |
| 誤検知・実行制限を避けたい | `nape-hud-<ver>-dotnet.zip`（52KB） | ランタイム 10 が必要 |

exe は**コード署名していない**ので SmartScreen が警告します。「詳細情報」→「実行」、
または `Unblock-File .\nape-hud.exe`。`SHA256SUMS.txt` でハッシュを照合できます。

止まって動かせない場合の対処は **[INSTALL.md](INSTALL.md)** に症状別でまとめています
（SmartScreen / ウイルス対策ソフトの誤検知 / CPU 種別の不一致 / 組織のポリシーで
exe が使えない場合 / 文字化け / ログオン時の自動起動）。

## GUI の使い方

`nape-hud-gui.exe` を起動すると通知領域に常駐します。ウィンドウは出ません。
レイヤー / 向き / DPI が切り替わると、画面の隅に数秒だけポップアップが出ます。

ポップアップは**クリックを透過**し、フォーカスも奪わず、タスクバーにも Alt-Tab にも
出ません。作業中に前面へ出ても操作を邪魔しません。

常駐アイコンを右クリックすると、

- **現在の状態を表示** — 今のレイヤー / 向き / DPI をポップアップで出す
- **キーアサインを表示…** — VIA プロトコルでデバイスから読み出す
- **接続状況…** — 認識しているインターフェースと、検出できる経路かどうか
- **設定ファイルを開く** — 無ければ `%APPDATA%\nape-hud\config.json` を作ってから開く
- **設定を読み込み直す** — 再起動せず反映する
- **終了**

アイコンには現在のレイヤー番号が出ます（`hud.menuBarShowsLayer` で切れます）。
表示位置・表示秒数・拡大率・ダイヤル表示は `config.json` の `hud` で変えられます。

デバイスは 3 秒ごとに見張っているので、抜き差しや接続方式の切り替えでも
勝手に貼り直します。検出できない接続で使っている場合は警告のバルーンが出ます。

起動時の表示位置を確かめるには `nape-hud-gui.exe --test`。

## CLI の使い方

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

読むのは `device` / `rules` / `layerNames` / `angleNames` / `dpiNames` / `keymap` と、
GUI では `hud` です。**ポインタ加速（`acceleration`）は macOS 版だけの機能**なので
無視されます。`hud` のうち `showConnection` / `showOnConnectionChange` も
接続方式を判定していないため効きません。

`learn` と `calibrate`（自動校正）も macOS 版のみです。角度の対応表を直したい場合は
`config.json` の `rules[].angle.map` と `angleNames` を直接編集してください。

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
cd windows
dotnet publish NapeHudCli -c Release -o dist        # CLI
dotnet publish NapeHudGui -c Release -o dist/gui    # GUI
```

配布物一式（CLI 3 アーキテクチャ + GUI + ランタイム依存版 + `SHA256SUMS.txt`）は
`windows/make-dist.sh` でまとめて作れます。

構成は 3 つのプロジェクトです。

| | 中身 |
|---|---|
| `NapeHudCore` | 設定の読み込み・復号・HID アクセス。UI を含まない |
| `NapeHudCli` | コンソール版 |
| `NapeHudGui` | 常駐 + ポップアップ（WinForms） |

GUI を単一ファイルにしていないのは、macOS 上での `PublishSingleFile` が
WinForms のファイル集合で失敗するためです（`GenerateBundle` が
`It is forbidden to change Manifest state…` で落ちる。大文字小文字を区別しない
ファイルシステム上での重複が原因と見られる）。Windows 上でビルドするなら
単一ファイルにできる可能性があります。

## 検証状況

- 復号ロジック（レイヤー / 向き / DPI の優先順位）は `selftest` で macOS 版と
  出力が一致することを確認済み。同じ `config.json` を読ませて突き合わせています。
  CLI と GUI はこのコードを共有しています。
- **HID アクセス（SetupAPI / hid.dll の P/Invoke）と GUI の描画は実機の Windows で
  未検証**です。開発機が macOS のため実行できていません。

うまくいかない場合は、まず CLI 版で切り分けてください。

```
nape-hud selftest    ここが通れば設定と復号は正常（デバイス不要）
nape-hud devices     デバイスを認識できているか
nape-hud run         実際に操作して状態が出るか
```

`run` まで通るのに GUI でポップアップが出ないなら描画側の問題です。
出力を添えて issue を立ててください。
