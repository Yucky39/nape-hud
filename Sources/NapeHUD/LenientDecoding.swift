import Foundation

// Swift の合成 init(from:) はキーが無いとプロパティ既定値を使わずエラーにする。
// 設定ファイルは「書きたい項目だけ書く」形にしたいので、欠損を既定値で埋める。

extension KeyedDecodingContainer {
    func opt<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        // try? はネストした Optional を平坦化するので、キー欠損・型不一致はどちらも nil になる。
        guard let v = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return v
    }
    func optNil<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension Config {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = c.opt(.device, DeviceMatch())
        hud = c.opt(.hud, HUDConfig())
        layerNames = c.opt(.layerNames, [:])
        angleNames = c.opt(.angleNames, [:])
        dpiNames = c.opt(.dpiNames, [:])
        rules = c.opt(.rules, [])
        keyFallback = c.opt(.keyFallback, KeyFallback())
        poll = c.opt(.poll, Poll())
        calibration = c.opt(.calibration, CalibrationConfig())
        keymap = c.opt(.keymap, KeymapConfig())
        acceleration = c.opt(.acceleration, AccelerationConfig())
    }
}

extension AccelerationConfig {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled)
        thresholdSpeed = c.opt(.thresholdSpeed, thresholdSpeed)
        fullSpeed = c.opt(.fullSpeed, fullSpeed)
        baseGain = c.opt(.baseGain, baseGain)
        maxGain = c.opt(.maxGain, maxGain)
        maxDeltaPerEvent = c.opt(.maxDeltaPerEvent, maxDeltaPerEvent)
        onlyTrackball = c.opt(.onlyTrackball, onlyTrackball)
        trackballActiveWindowMs = c.opt(.trackballActiveWindowMs, trackballActiveWindowMs)
        perLayerGain = c.opt(.perLayerGain, perLayerGain)
        smoothing = c.opt(.smoothing, smoothing)
        rampPerSecond = c.opt(.rampPerSecond, rampPerSecond)
        rampDownFactor = c.opt(.rampDownFactor, rampDownFactor)
        displayScaling = c.opt(.displayScaling, DisplayScalingConfig())
    }
}

extension DisplayScalingConfig {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled)
        metric = c.opt(.metric, metric)
        referenceSize = c.opt(.referenceSize, referenceSize)
        minScale = c.opt(.minScale, minScale)
        maxScale = c.opt(.maxScale, maxScale)
    }
}

extension KeymapConfig {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keysPerLayer = c.opt(.keysPerLayer, keysPerLayer)
        layerCount = c.opt(.layerCount, layerCount)
    }
}

extension CalibrationConfig {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positions = c.opt(.positions, positions)
        angleZeroCode = c.optNil(.angleZeroCode)
        clockwise = c.opt(.clockwise, clockwise)
    }
}

extension DeviceMatch {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendorId = c.opt(.vendorId, vendorId)
        productIds = c.opt(.productIds, productIds)
        productNameContains = c.opt(.productNameContains, productNameContains)
        connectionNames = c.opt(.connectionNames, connectionNames)
        usagePages = c.opt(.usagePages, usagePages)
    }
}

extension HUDConfig {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = c.opt(.seconds, seconds)
        position = c.opt(.position, position)
        margin = c.opt(.margin, margin)
        scale = c.opt(.scale, scale)
        showConnection = c.opt(.showConnection, showConnection)
        showOnConnectionChange = c.opt(.showOnConnectionChange, showOnConnectionChange)
        showAngleDial = c.opt(.showAngleDial, showAngleDial)
        followsMouseScreen = c.opt(.followsMouseScreen, followsMouseScreen)
        showMenuBarIcon = c.opt(.showMenuBarIcon, showMenuBarIcon)
        menuBarShowsLayer = c.opt(.menuBarShowsLayer, menuBarShowsLayer)
        layerNumberOffset = c.opt(.layerNumberOffset, layerNumberOffset)
    }
}

extension Rule {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.opt(.name, "")
        usagePage = c.optNil(.usagePage)
        usage = c.optNil(.usage)
        reportId = c.optNil(.reportId)
        minLength = c.optNil(.minLength)
        match = c.optNil(.match)
        layer = c.optNil(.layer)
        angle = c.optNil(.angle)
        dpi = c.optNil(.dpi)
        notify = c.opt(.notify, notify)
    }
}

extension KeyFallback {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled)
        consume = c.opt(.consume, consume)
        bindings = c.opt(.bindings, bindings)
    }
}

extension Poll {
    init(from decoder: Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled)
        usagePage = c.opt(.usagePage, usagePage)
        usage = c.opt(.usage, usage)
        reportId = c.opt(.reportId, reportId)
        request = c.opt(.request, request)
        intervalMs = c.opt(.intervalMs, intervalMs)
    }
}
