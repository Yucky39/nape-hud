import Foundation
import IOKit.hid

/// Nape Pro の raw HID (0xFF60) は VIA プロトコルの問い合わせに応答する。
/// 実機で確認できたコマンド:
///   0x01 プロトコル版数 / 0x11 レイヤー数 / 0x0C マクロ数
///   0x12 キーマップ読み出し（offset 2 バイト + 長さ 1 バイト）
///   0x14 エンコーダ読み出し（レイヤー, エンコーダ番号, 時計回りか）
///
/// 応答は先頭に要求バイトがそのまま返り、その後ろにデータが続く。
/// 送信（SetReport）と受信（入力レポート）が別経路なので、要求ごとに応答を待ち合わせる。
final class VIAClient {

    struct Snapshot {
        var protocolVersion: Int
        var layerCount: Int
        var macroCount: Int
        var keysPerLayer: Int
        /// keymap[layer][key]
        var keymap: [[UInt16]]
        /// encoders[layer] = (時計回り, 反時計回り)
        var encoders: [(cw: UInt16, ccw: UInt16)]
        /// 使われているエンコーダの個数（実測では 1）
        var encoderCount: Int
        /// マトリクスの行数（0x04 の座標読みで判明した範囲）
        var matrixRows: Int
        /// 一括読み（0x12）の解釈が座標読み（0x04）と一致したか。
        /// 一致していればキー数の自動判定が正しいと確認できたことになる。
        var coordinateVerified: Bool
        /// マクロが 1 つも定義されていないか
        var macrosEmpty: Bool
        /// デバイスが申告したレイヤー数（表示用に絞る前の値）
        var reportedLayerCount: Int
    }

    private let device: IOHIDDevice
    /// マネージャを保持し続けること。解放されると配下のデバイスも閉じられ、
    /// 以降の SetReport が kIOReturnNotOpen (0xE00002CD) で失敗する。
    private let manager: IOHIDManager
    private var pending: [UInt8]?
    private var buffer = [UInt8](repeating: 0, count: 64)

    private init(device: IOHIDDevice, manager: IOHIDManager) {
        self.device = device
        self.manager = manager
    }

    // MARK: - 取得

    /// 別スレッドで読み出して主スレッドに返す。
    /// 応答待ちに実行ループを回すので、主スレッドで直接やると再入して危険。
    static func readSnapshot(match: DeviceMatch,
                             settings: KeymapConfig,
                             completion: @escaping (Result<Snapshot, Error>) -> Void) {
        let thread = Thread {
            let result: Result<Snapshot, Error>
            do {
                let client = try VIAClient.open(match: match)
                result = .success(try client.snapshot(settings: settings))
                client.close()
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        thread.name = "nape-hud.via"
        thread.start()
    }

    private static func open(match: DeviceMatch) throws -> VIAClient {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: match.vendorId,
            kIOHIDPrimaryUsagePageKey: 0xFF60,
        ] as CFDictionary)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            throw Err("raw HID (0xFF60) を開けませんでした。")
        }
        let dev = set.first { d in
            let pid = intProp(d, kIOHIDProductIDKey) ?? 0
            let product = strProp(d, kIOHIDProductKey) ?? ""
            return match.matches(vid: match.vendorId, pid: pid, product: product)
        }
        guard let dev else {
            throw Err("Nape Pro の raw HID インターフェース (0xFF60) が見つかりません。接続を確認してください。")
        }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw Err("raw HID インターフェースを開けませんでした。")
        }

        let client = VIAClient(device: dev, manager: mgr)
        let ctx = Unmanaged.passUnretained(client).toOpaque()
        client.buffer.withUnsafeMutableBufferPointer { p in
            IOHIDDeviceRegisterInputReportCallback(dev, p.baseAddress!, p.count, { ctx, _, _, _, _, rep, len in
                guard let ctx, len > 0 else { return }
                let me = Unmanaged<VIAClient>.fromOpaque(ctx).takeUnretainedValue()
                me.pending = [UInt8](UnsafeBufferPointer(start: rep, count: len))
            }, ctx)
        }
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return client
    }

    private func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - 1 往復

    /// 要求を送って応答を待つ。応答は先頭が要求と一致するものだけ採用する
    /// （デバイスは状態通知 0xA3 なども同じ経路に流してくるため）。
    private func request(_ bytes: [UInt8], timeout: TimeInterval = 0.5) throws -> [UInt8] {
        let payload = bytes + [UInt8](repeating: 0, count: max(0, 32 - bytes.count))
        pending = nil
        let r = payload.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, 32)
        }
        guard r == kIOReturnSuccess else {
            throw Err("問い合わせの送信に失敗しました (\(String(format: "0x%08X", UInt32(bitPattern: r))))")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
            if let got = pending {
                pending = nil
                // 要求バイト列が先頭に返るのが VIA の約束。違うものは読み飛ばす。
                if got.count >= bytes.count, Array(got.prefix(bytes.count)) == bytes {
                    return got
                }
            }
        }
        throw Err("デバイスが応答しませんでした（\(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))）。"
                  + "\nKeychron Launcher が開いていると応答を取り合ってしまうため、閉じてから試してください。")
    }

    // MARK: - まとめて読む

    private func snapshot(settings: KeymapConfig) throws -> Snapshot {
        let keysPerLayerOverride = settings.keysPerLayer
        let ver = try request([0x01])
        let protocolVersion = Int(ver[1]) << 8 | Int(ver[2])

        let layers = try request([0x11])
        let reportedLayerCount = max(Int(layers[1]), 1)
        // 申告値より実際に使えるレイヤーが少ないことがある（Nape Pro は 9 を返すが 8 レイヤー）。
        // キー数の割り出しには申告値を使い、表示は絞った値を使う。
        let layerCount = settings.layerCount > 0
            ? min(settings.layerCount, reportedLayerCount)
            : reportedLayerCount

        let macros = try request([0x0C])
        let macroCount = Int(macros[1])

        // キーマップ本体。1 回で読めるのは 28 バイト（32 - ヘッダ 4）。
        // 末尾まで読み進め、非ゼロの最後からキー数を割り出す。
        let chunk = 28
        var raw: [UInt8] = []
        var offset = 0
        let hardLimit = 1024
        while offset < hardLimit {
            let resp = try request([0x12, UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), UInt8(chunk)])
            guard resp.count >= 4 + chunk else { break }
            let data = Array(resp[4..<(4 + chunk)])
            raw += data
            offset += chunk
            // 2 チャンク続けて全ゼロなら終端とみなす
            if raw.count >= chunk * 2,
               raw.suffix(chunk * 2).allSatisfy({ $0 == 0 }) { break }
        }

        var codes: [UInt16] = []
        for i in stride(from: 0, to: raw.count - 1, by: 2) {
            codes.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
        }

        let keysPerLayer: Int
        if keysPerLayerOverride > 0 {
            keysPerLayer = keysPerLayerOverride
        } else if let last = codes.lastIndex(where: { $0 != 0 }) {
            // バッファは申告レイヤー数ぶん確保されているので、割り算には申告値を使う。
            // 表示を 8 レイヤーに絞っていても、1 レイヤーあたりの刻み幅は変わらない。
            // 実測では 9（申告）× 7 キー = 63 個で非ゼロが尽きる。
            keysPerLayer = max(1, Int((Double(last + 1) / Double(reportedLayerCount)).rounded(.up)))
        } else {
            keysPerLayer = 0
        }

        var keymap: [[UInt16]] = []
        if keysPerLayer > 0 {
            for l in 0..<layerCount {
                let start = l * keysPerLayer
                let end = min(start + keysPerLayer, codes.count)
                keymap.append(start < end ? Array(codes[start..<end]) : [])
            }
        }

        var encoders: [(cw: UInt16, ccw: UInt16)] = []
        for l in 0..<layerCount {
            // エンコーダが無い機種では応答しないので、失敗しても全体は成立させる
            let cw = (try? request([0x14, UInt8(l), 0x00, 0x01])).flatMap(Self.value) ?? 0
            let ccw = (try? request([0x14, UInt8(l), 0x00, 0x00])).flatMap(Self.value) ?? 0
            encoders.append((cw, ccw))
        }

        // エンコーダの個数。番号を上げていき、全レイヤーで無反応なら打ち止め。
        var encoderCount = 0
        for e in 0..<8 {
            let cw = (try? request([0x14, 0x00, UInt8(e), 0x01])).flatMap(Self.value) ?? 0
            let ccw = (try? request([0x14, 0x00, UInt8(e), 0x00])).flatMap(Self.value) ?? 0
            if cw == 0 && ccw == 0 { break }
            encoderCount = e + 1
        }

        // 0x04（レイヤー・行・列を指定した読み出し）で一括読みの解釈を検算する。
        // 一致すればキー数の自動判定が正しいと確認できる。
        var coordinateVerified = false
        if keysPerLayer > 0, let first = keymap.first, first.count == keysPerLayer {
            var byCoordinate: [UInt16] = []
            for c in 0..<keysPerLayer {
                let v = (try? request([0x04, 0x00, 0x00, UInt8(c)])).flatMap(Self.value) ?? 0
                byCoordinate.append(v)
            }
            coordinateVerified = byCoordinate == first
        }

        // 行数。行 1 以降に非ゼロがあるかを見る（実測では 1 行のみ）。
        var matrixRows = 1
        for row in 1..<8 {
            var any = false
            for c in 0..<keysPerLayer {
                let v = (try? request([0x04, 0x00, UInt8(row), UInt8(c)])).flatMap(Self.value) ?? 0
                if v != 0 { any = true; break }
            }
            if !any { break }
            matrixRows = row + 1
        }

        // マクロが使われているか
        let macroHead = (try? request([0x0E, 0x00, 0x00, 0x1C])) ?? []
        let macrosEmpty = macroHead.count >= 32
            ? macroHead[4..<32].allSatisfy { $0 == 0 }
            : false

        return Snapshot(protocolVersion: protocolVersion, layerCount: layerCount,
                        macroCount: macroCount, keysPerLayer: keysPerLayer,
                        keymap: keymap, encoders: encoders,
                        encoderCount: encoderCount, matrixRows: matrixRows,
                        coordinateVerified: coordinateVerified, macrosEmpty: macrosEmpty,
                        reportedLayerCount: reportedLayerCount)
    }

    /// 0x14 の応答からキーコードを取り出す（ヘッダ 4 バイトの後ろの 2 バイト）
    private static func value(_ resp: [UInt8]) -> UInt16? {
        guard resp.count >= 6 else { return nil }
        return UInt16(resp[4]) << 8 | UInt16(resp[5])
    }
}
