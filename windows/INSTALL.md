# Windows 版が実行できないときの代替手段

## まず前提

**インストーラはありません。** 置いて実行するだけです。
インストール作業も管理者権限もレジストリ変更も不要で、消すときはファイルを削除するだけです。

```
> .\nape-hud-gui.exe          GUI（常駐してポップアップを出す）
> .\nape-hud.exe devices      CLI（コンソールに出す・診断もこちら）
```

GUI はフォルダ配布なので、展開したフォルダごと置いてください。
中の `nape-hud-gui.exe` だけ抜き出すと動きません。

「インストールできない」場合、実際には次のどれかで止まっています。症状から選んでください。

| 症状 | 原因 | → |
|---|---|---|
| 「Windows によって PC が保護されました」 | SmartScreen（未署名） | [1](#1-smartscreen-で止まる) |
| 起動直後に消える / ウイルス判定 | AV の誤検知 | [2](#2-ウイルス対策ソフトに消される) |
| 「このアプリは PC で実行できません」 | CPU 種別の不一致 | [3](#3-このアプリは-pc-で実行できません) |
| exe をダウンロードできない | 組織のポリシー | [4](#4-exe-そのものを持ち込めない) |
| exe の実行が禁止されている | AppLocker など | [4](#4-exe-そのものを持ち込めない) |
| 文字が □ や ? になる | コンソールの文字コード | [6](#6-文字化けする) |
| GUI が起動しても何も起きない | — | [8](#8-gui-が起動しているのにポップアップが出ない) |

---

## 1. SmartScreen で止まる

配布している exe は**コード署名されていません**（Authenticode 証明書を持っていないため）。
インターネットから落ちたファイルには「Mark of the Web」が付き、SmartScreen が警告します。

**画面から:** 「詳細情報」→「実行」。

**PowerShell から:**

```powershell
Unblock-File .\nape-hud.exe
```

実行前にハッシュを照合しておくと確実です。Release の `SHA256SUMS.txt` と比べてください。

```powershell
Get-FileHash .\nape-hud.exe -Algorithm SHA256
```

## 2. ウイルス対策ソフトに消される

**単一ファイル形式の .NET アプリは誤検知されやすい**です（実行時に自分を展開する挙動が
パッカーと似ているため）。実際にどう対処するかは 3 通りあります。

**(a) 除外に追加する** — 置き場所を決めてからフォルダごと除外します。
これは**管理者として実行した PowerShell が必要**です。

```powershell
Add-MpPreference -ExclusionPath "C:\tools\nape-hud"
```

**(b) 単一ファイルをやめる** — `-dotnet.zip` は単一ファイルではない通常の
.NET アセンブリ（**50KB 前後**）なので、誤検知の対象になりにくいです。
[.NET 10](https://dotnet.microsoft.com/download/dotnet/10.0) が必要です
（CLI はランタイム、GUI は**デスクトップランタイム**）。

```
> dotnet nape-hud.dll devices        CLI
> dotnet nape-hud-gui.dll            GUI
```

なお GUI のランタイム同梱版はもともと単一ファイルではないので、
この問題は起きにくいです。

**(c) 自分でビルドする** → [5](#5-ソースからビルドする)。ダウンロードした実行ファイルを
一切使わないので、この問題自体が起きません。

> 誤検知だと思われる場合は Microsoft に報告できます。
> https://www.microsoft.com/wdsi/filesubmission

## 3. 「このアプリは PC で実行できません」

CPU の種別が合っていません。Release には 3 種類あります。

| PC | ファイル |
|---|---|
| ふつうの Windows 10/11 | `nape-hud-<ver>-win-x64.zip` |
| ARM 版 Windows（Snapdragon 機など） | `nape-hud-<ver>-win-arm64.zip` |
| 32bit Windows | `nape-hud-<ver>-win-x86.zip` |

GUI は x64 版のみです。ARM 機ではエミュレーションで動きます。
32bit Windows で GUI を使いたい場合はソースからビルドしてください（[5](#5-ソースからビルドする)）。

確認方法:

```powershell
$env:PROCESSOR_ARCHITECTURE      # AMD64 / ARM64 / x86
```

ARM 機は x64 版もエミュレーションで動きますが、arm64 版のほうが軽く確実です。

## 4. exe そのものを持ち込めない

**exe のダウンロードが禁止されている場合** → zip 版を使ってください。展開すれば同じものです。

**exe の実行自体が禁止されている場合**（AppLocker / WDAC など） → `nape-hud-<ver>-dotnet.zip`
を使います。中身は `nape-hud.dll` で、実行するのは OS が許可済みの `dotnet.exe` です。

```
> dotnet nape-hud.dll run
```

**どちらも無理な場合** → 残る手は [5](#5-ソースからビルドする) です。それも通らない環境なら、
そもそもツールを持ち込めない設定なので、管理者に相談してください。

## 5. ソースからビルドする

[.NET SDK 10](https://dotnet.microsoft.com/download/dotnet/10.0) が必要です。
ビルドは Windows でも macOS でも Linux でもできます。

```
> git clone https://github.com/Yucky39/nape-hud.git
> cd nape-hud\windows
> dotnet publish NapeHudCli -c Release -o dist          CLI
> dotnet publish NapeHudGui -c Release -o dist\gui      GUI
```

自分でビルドしたものは Mark of the Web が付かないので SmartScreen に止められません。

別のアーキテクチャ向けにするなら `-r win-arm64` / `-r win-x86` を付けます。

ビルドせず直接動かすこともできます。

```
> dotnet run --project NapeHudCli -- devices
> dotnet run --project NapeHudGui
```

配布物一式（3 アーキテクチャ + ランタイム依存版 + ハッシュ）をまとめて作るなら:

```sh
windows/make-dist.sh
```

## 6. 文字化けする

出力は UTF-8 です。旧来のコマンドプロンプトだと日本語が □ になることがあります。
**Windows Terminal** を使うのが一番簡単です。`conhost` のままなら:

```
> chcp 65001
```

## 7. ログオン時に自動で動かしたい

**GUI 版**なら、下の「簡単な方法」で `nape-hud-gui.exe` のショートカットを
スタートアップに置くのが素直です。常駐アイコンから終了できます。

**CLI 版**を常駐させたい場合、macOS 版と違ってサービスにはしていません。

**簡単な方法** — スタートアップフォルダにショートカットを置きます。管理者権限は不要です。

```powershell
# GUI なら $exe を nape-hud-gui.exe にして、Arguments は "" にする
$exe = "C:\tools\nape-hud\nape-hud.exe"
$lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\nape-hud.lnk"
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = $exe; $s.Arguments = "run"
$s.WorkingDirectory = Split-Path $exe
$s.Save()
```

CLI 版だとコンソールウィンドウが 1 つ出たままになります（GUI 版は出ません）。
やめるときは `Remove-Item $lnk`。

**ウィンドウを出さずログに残す方法** — タスクスケジューラに登録します。
自分として動くタスクなので通常は管理者権限なしで登録できますが、環境によっては
昇格を求められます。

```powershell
$exe = "C:\tools\nape-hud\nape-hud.exe"
$log = "$env:LOCALAPPDATA\nape-hud\run.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

$action  = New-ScheduledTaskAction -Execute "cmd.exe" `
           -Argument "/c `"`"$exe`" run >> `"$log`" 2>&1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable `
           -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName "nape-hud" -Action $action `
  -Trigger $trigger -Settings $set -Description "Keychron Nape Pro の状態をログに記録"
```

コンソールを出したくないので `cmd /c` 経由でログファイルに追記しています。
やめるときは `Unregister-ScheduledTask -TaskName "nape-hud" -Confirm:$false`。

> CLI 版に画面表示はありません。ポップアップが欲しい場合は GUI 版を使ってください。

## 8. GUI が起動しているのにポップアップが出ない

通知領域のアイコンを右クリック → **接続状況…** を見てください。
`0xFF60` の面を掴めていなければ、その接続方式では検出できません
（Bluetooth では原理的に不可）。

アイコン自体が出ない場合は `hud.showMenuBarIcon` が `false` になっていないか確認してください。
`false` だと終了操作もできなくなるので、タスクマネージャーから終了させることになります。

表示位置がおかしい / 画面外に出ている場合は `nape-hud-gui.exe --test` で位置を確認し、
`config.json` の `hud.position`（`topRight` / `topLeft` / `bottomRight` / `bottomLeft` /
`center`）と `hud.margin` を調整してください。

それでも切り分けられない場合は CLI 版の `run` を試してください。`run` で出るのに
GUI で出ないなら描画側の問題です。

## 動いたかどうかの確認手順

必ずこの順で試してください。どこで止まったかで原因が切り分けられます。

```
> .\nape-hud.exe selftest    デバイス不要。ここが通れば復号ロジックは正常
> .\nape-hud.exe devices     デバイスを認識できているか、経路が対応しているか
> .\nape-hud.exe run         実際にレイヤー / 向き / DPI ボタンを操作してみる
```

- `selftest` が失敗する → `config.json` の問題
- `devices` で見つからない → 接続方式の問題。**Bluetooth では原理的に検出できません**
  （USB 有線か 2.4GHz ドングルを使ってください）
- `devices` は通るのに `run` で何も出ない → HID 読み出しの問題。出力を添えて issue へ

## 設定ファイルと消し方

設定は `%APPDATA%\nape-hud\config.json` に置きます（無くても内蔵の既定値で動きます）。

消すときは exe と `%APPDATA%\nape-hud` を削除するだけです。
タスクスケジューラに登録した場合はそれも解除してください。
