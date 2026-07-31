import Foundation
import IOKit.hid

// MARK: - 接続種別

enum Connection: String {
    case usb = "USB"
    case dongle = "2.4GHz"
    case bluetooth = "Bluetooth"
    case unknown = "?"

    var symbol: String {
        switch self {
        case .usb: return "USB-C"
        case .dongle: return "2.4G"
        case .bluetooth: return "BT"
        case .unknown: return "—"
        }
    }
}

// MARK: - 受信レポート

struct ReportEvent {
    let usagePage: Int
    let usage: Int
    let reportId: Int
    let bytes: [UInt8]
    let connection: Connection
    let product: String
}

// MARK: - 1 インターフェース分の受信バッファ保持

private final class Interface {
    let device: IOHIDDevice
    let usagePage: Int
    let usage: Int
    let product: String
    let connection: Connection
    /// IOHIDDeviceRegisterInputReportCallback に渡すバッファはコールバック登録が生きている間ずっと有効でなければならない。
    var buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int
    var onReport: ((ReportEvent) -> Void)?

    init(device: IOHIDDevice, usagePage: Int, usage: Int, product: String,
         connection: Connection, bufferSize: Int) {
        self.device = device
        self.usagePage = usagePage
        self.usage = usage
        self.product = product
        self.connection = connection
        self.bufferSize = max(bufferSize, 64)
        self.buffer = .allocate(capacity: self.bufferSize)
        self.buffer.initialize(repeating: 0, count: self.bufferSize)
    }

    deinit { buffer.deallocate() }

    var label: String { String(format: "%04X/%02X", usagePage, usage) }
}

// MARK: - モニタ本体

final class HIDMonitor {
    private let match: DeviceMatch
    /// 監視するインターフェース。空なら全面（「入力監視」の許可が必要）。
    private let usagePages: [Int]
    private var manager: IOHIDManager?
    private var interfaces: [IOHIDDevice: Interface] = [:]

    /// レポート到着
    var onReport: ((ReportEvent) -> Void)?
    /// 接続/切断（接続種別つき）
    var onConnectionChange: ((Connection, Bool, String) -> Void)?
    /// 人間向けログ（sniff モードで使う）
    var onLog: ((String) -> Void)?

    /// - Parameter allUsagePages: true で全インターフェースを対象にする（`--pointer` 相当）
    init(match: DeviceMatch, allUsagePages: Bool = false) {
        self.match = match
        self.usagePages = allUsagePages ? [] : match.usagePages
    }

    /// キーボード/ポインタ面を含む設定になっているか（＝「入力監視」の許可が必要か）
    var needsInputMonitoring: Bool {
        usagePages.isEmpty || usagePages.contains(0x01)
    }

    /// 現在アクティブな接続種別（複数ある場合は USB > 2.4GHz > BT の優先順）
    var activeConnection: Connection {
        let kinds = Set(interfaces.values.map(\.connection))
        for k in [Connection.usb, .dongle, .bluetooth] where kinds.contains(k) { return k }
        return .unknown
    }

    func start() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // PID / 製品名の判定はコールバック側で行う（BT 接続時に PID が変わる機種でも
        // 取りこぼさないため）。ただしインターフェースはここで絞る:
        // キーボード面を対象に含めると IOHIDManagerOpen 自体が「入力監視」の許可を要求し、
        // 未許可だと kIOReturnNotPermitted で失敗して 1 件も受信できなくなる。
        if usagePages.isEmpty {
            IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: match.vendorId] as CFDictionary)
        } else {
            let dicts = usagePages.map {
                [kIOHIDVendorIDKey: match.vendorId, kIOHIDPrimaryUsagePageKey: $0] as CFDictionary
            }
            IOHIDManagerSetDeviceMatchingMultiple(mgr, dicts as CFArray)
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            if r == kIOReturnNotPermitted {
                throw Err("""
                    HID の読み取りを macOS に拒否されました（kIOReturnNotPermitted）。
                    キーボード/ポインタ面を監視対象に含めているため「入力監視」の許可が必要です。
                    システム設定 → プライバシーとセキュリティ → 入力監視 で許可するか、
                    config.json の device.usagePages をベンダ面のみ（[65376, 140]）にしてください。
                    """)
            }
            throw Err("IOHIDManager を開けませんでした (\(String(format: "0x%08X", UInt32(bitPattern: r))))")
        }
    }

    // MARK: - デバイス出入り

    private func deviceAdded(_ device: IOHIDDevice) {
        let vid = intProp(device, kIOHIDVendorIDKey) ?? 0
        let pid = intProp(device, kIOHIDProductIDKey) ?? 0
        let product = strProp(device, kIOHIDProductKey) ?? ""
        guard match.matches(vid: vid, pid: pid, product: product) else { return }
        guard interfaces[device] == nil else { return }

        let usagePage = intProp(device, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = intProp(device, kIOHIDPrimaryUsageKey) ?? 0
        let conn = connection(of: device, pid: pid, product: product)
        let size = intProp(device, kIOHIDMaxInputReportSizeKey) ?? 64

        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard open == kIOReturnSuccess else {
            onLog?("open 失敗 \(String(format: "%04X/%02X", usagePage, usage)) (0x\(String(open, radix: 16)))")
            return
        }

        let iface = Interface(device: device, usagePage: usagePage, usage: usage,
                              product: product, connection: conn, bufferSize: size)
        iface.onReport = { [weak self] ev in self?.onReport?(ev) }
        interfaces[device] = iface

        let ictx = Unmanaged.passUnretained(iface).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, iface.buffer, iface.bufferSize, { ctx, _, _, _, rid, report, len in
            guard let ctx, len > 0 else { return }
            let i = Unmanaged<Interface>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = [UInt8](UnsafeBufferPointer(start: report, count: len))
            i.onReport?(ReportEvent(usagePage: i.usagePage, usage: i.usage, reportId: Int(rid),
                                    bytes: bytes, connection: i.connection, product: i.product))
        }, ictx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        onLog?("+ \(product) [\(conn.rawValue)] \(iface.label) in=\(size)B")
        // 同一デバイスの複数インターフェースが順に来るので、接続通知は種別が新規のときだけ出す。
        let othersWithSameKind = interfaces.values.filter { $0.connection == conn }.count
        if othersWithSameKind == 1 { onConnectionChange?(conn, true, product) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let iface = interfaces.removeValue(forKey: device) else { return }
        onLog?("- \(iface.product) [\(iface.connection.rawValue)] \(iface.label)")
        if !interfaces.values.contains(where: { $0.connection == iface.connection }) {
            onConnectionChange?(iface.connection, false, iface.product)
        }
    }

    // MARK: - 接続種別の判定

    private func connection(of device: IOHIDDevice, pid: Int, product: String) -> Connection {
        if let name = match.connectionOverride(pid: pid) {
            switch name.lowercased() {
            case "usb": return .usb
            case "2.4ghz", "2.4g", "dongle", "rf": return .dongle
            case "bluetooth", "bt", "ble": return .bluetooth
            default: break
            }
        }
        let transport = (strProp(device, kIOHIDTransportKey) ?? "").lowercased()
        if transport.contains("bluetooth") { return .bluetooth }
        let hay = (product + " " + (strProp(device, kIOHIDManufacturerKey) ?? "")).lowercased()
        for token in ["2.4g", "2.4 g", "dongle", "receiver", "wireless"] where hay.contains(token) {
            return .dongle
        }
        if transport.contains("usb") { return .usb }
        if transport.isEmpty { return .unknown }
        return .usb
    }

    // MARK: - ポーリング送信

    /// 状態を自発通知しないファームウェア向けに、こちらから問い合わせレポートを送る。
    func send(usagePage: Int, usage: Int, reportId: Int, bytes: [UInt8]) {
        for iface in interfaces.values where iface.usagePage == usagePage && iface.usage == usage {
            var payload = bytes
            let outSize = intProp(iface.device, kIOHIDMaxOutputReportSizeKey) ?? payload.count
            if payload.count < outSize { payload += [UInt8](repeating: 0, count: outSize - payload.count) }
            _ = payload.withUnsafeBufferPointer { p in
                IOHIDDeviceSetReport(iface.device, kIOHIDReportTypeOutput, CFIndex(reportId),
                                     p.baseAddress!, p.count)
            }
        }
    }

    /// 監視をやめる。参照を捨てるだけでも止まるが、明示的に閉じたほうが確実。
    func stop() {
        for (device, _) in interfaces {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(),
                                             CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        interfaces.removeAll()
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(),
                                              CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    var interfaceSummary: [String] {
        interfaces.values
            .map { "\($0.label) [\($0.connection.rawValue)] \($0.product)" }
            .sorted()
    }
}

// MARK: - プロパティ取得ヘルパ

func intProp(_ d: IOHIDDevice, _ key: String) -> Int? {
    IOHIDDeviceGetProperty(d, key as CFString) as? Int
}
func strProp(_ d: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(d, key as CFString) as? String
}

/// キーボード/ポインタ面のレポート受信には「入力監視」権限が必要。
func inputMonitoringGranted() -> Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
}
func requestInputMonitoring() -> Bool {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
}
