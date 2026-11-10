import Foundation

/// How a device is drawn: its SF Symbol, and whether it's worn (so the volume HUD shows it in place
/// of a speaker).
nonisolated struct DeviceLook: Equatable, Sendable {
    let symbol: String
    let isPersonal: Bool

    init(_ symbol: String, personal: Bool) {
        self.symbol = symbol
        isPersonal = personal
    }
}

/// Apple and Beats headphones by Bluetooth product ID, as SF Symbols draw them.
nonisolated enum AppleAudioModel {
    static let vendorID = 0x004C

    private static let symbols: [Int: String] = [
        0x2002: "airpods", 0x200F: "airpods", 0x2013: "airpods.gen3", 0x2019: "airpods.gen4", 0x201B: "airpods.gen4",
        0x200E: "airpods.pro", 0x2014: "airpods.pro", 0x2024: "airpods.pro", 0x2027: "airpods.pro",
        0x200A: "airpods.max", 0x201F: "airpods.max",
        0x2003: "beats.powerbeats3", 0x200D: "beats.powerbeats", 0x200B: "beats.powerbeats.pro",
        0x2005: "beats.earphones", 0x2010: "beats.earphones",
        0x2006: "beats.headphones", 0x2009: "beats.headphones", 0x200C: "beats.headphones", 0x2017: "beats.headphones",
        0x2011: "beats.studiobuds", 0x2016: "beats.studiobudsplus", 0x2012: "beats.fitpro",
    ]

    static func symbol(for product: Int) -> String? { symbols[product] }

    /// The charging case that goes with the earbuds' symbol.
    static func caseSymbol(for symbol: String) -> String {
        switch symbol {
        case "airpods.gen3": "airpods.gen3.chargingcase.wireless"
        case "airpods.gen4": "airpods.gen4.chargingcase.wireless"
        case "airpods.pro", "airpodspro": "airpods.pro.chargingcase.wireless"
        case "beats.studiobuds": "beats.studiobuds.chargingcase"
        case "beats.studiobudsplus": "beats.studiobudsplus.chargingcase"
        case "beats.fitpro": "beats.fitpro.chargingcase"
        case "beats.solobuds": "beats.solobuds.chargingcase"
        case "beats.powerbeats.pro", "beats.powerbeatspro": "beats.powerbeatspro.chargingcase"
        case "earbuds": "earbuds.case.fill"
        default: "airpods.chargingcase"
        }
    }
}

/// Works out what a device is from whatever it gives away: a model ID, its name, its Bluetooth class.
nonisolated enum DeviceSymbol {
    /// Symbols that only say what kind of thing a device is, which a closer look may improve on.
    static let generic: Set<String> = ["headphones", "earbuds", "airpods", "hifispeaker.fill", "speaker.wave.2.fill", "wave.3.right"]

    /// Headphones of any kind, rather than something across the room.
    static func isWorn(_ symbol: String) -> Bool {
        symbol.hasPrefix("airpods") || symbol.hasPrefix("headphones") || symbol == "earpods" || symbol == "earbuds"
            || (symbol.hasPrefix("beats.") && !symbol.hasPrefix("beats.pill"))
    }

    /// CoreAudio's model UID for a Bluetooth device: the product and vendor IDs in hex, "2014 4c"
    /// for AirPods Pro 2. It names the model however the device has been renamed, and needs no
    /// Bluetooth permission.
    static func look(forModelUID uid: String) -> DeviceLook? {
        let parts = uid.split(separator: " ")
        guard parts.count == 2, let product = Int(parts[0], radix: 16), let vendor = Int(parts[1], radix: 16),
              vendor == AppleAudioModel.vendorID, let symbol = AppleAudioModel.symbol(for: product) else { return nil }
        return DeviceLook(symbol, personal: true)
    }

    /// What a device's name gives away. Rules run most specific first: "AirPods Pro" before
    /// "AirPods", "MacBook Air Speakers" before "speakers".
    static func look(forName name: String) -> DeviceLook? {
        let lowered = name.lowercased()
        let words = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let has = { (parts: [String]) in parts.contains { lowered.contains($0) } }
        let worn = { (symbol: String) in DeviceLook(symbol, personal: true) }
        let thing = { (symbol: String) in DeviceLook(symbol, personal: false) }

        // Apple's own headphones.
        if has(["airpods max"]) { return worn("airpods.max") }
        if has(["airpods pro"]) { return worn("airpods.pro") }
        if has(["airpods 4", "airpods (4"]) { return worn("airpods.gen4") }
        if has(["airpods (3", "airpods 3"]) { return worn("airpods.gen3") }
        if has(["airpods"]) { return worn("airpods") }
        if has(["earpods"]) { return worn("earpods") }
        // Beats.
        if has(["powerbeats pro"]) { return worn("beats.powerbeats.pro") }
        if has(["powerbeats"]) { return worn("beats.powerbeats") }
        if has(["studio buds+", "studio buds +", "studio buds plus"]) { return worn("beats.studiobudsplus") }
        if has(["studio buds"]) { return worn("beats.studiobuds") }
        if has(["solo buds"]) { return worn("beats.solobuds") }
        if has(["beats fit", "fit pro"]) && has(["beats"]) { return worn("beats.fitpro") }
        if has(["beats flex", "beatsx", "beats x"]) { return worn("beats.earphones") }
        if has(["beats pill", "pill+"]) { return thing("beats.pill.fill") }
        if has(["beats"]) { return worn("beats.headphones") }
        // Apple speakers and screens.
        if has(["homepod mini"]) { return thing("homepodmini.fill") }
        if has(["homepod"]) { return thing("homepod.fill") }
        if has(["apple tv"]) { return thing("appletv.fill") }
        // A Mac's own speakers, or a Mac itself.
        if has(["macbook"]) { return thing("macbook") }
        if has(["imac"]) { return thing("desktopcomputer") }
        if has(["mac mini"]) { return thing("macmini.fill") }
        if has(["mac studio"]) { return thing("macstudio.fill") }
        if has(["mac pro"]) { return thing("macpro.gen3.fill") }
        // Other Apple devices.
        if has(["iphone"]) { return thing("iphone") }
        if has(["ipad"]) { return thing("ipad") }
        if has(["apple watch"]) { return thing("applewatch") }
        if has(["vision pro"]) { return thing("visionpro") }
        if has(["apple pencil"]) { return thing("applepencil.tip") }
        // Keyboards, mice, trackpads, controllers.
        if has(["trackpad", "触控板"]) { return thing("rectangle.and.hand.point.up.left.fill") }
        if has(["magic mouse"]) { return thing("magicmouse.fill") }
        if has(["keyboard", "键盘", "keychron", "hhkb"]) { return thing("keyboard.fill") }
        if has(["mouse", "鼠标", "mx master", "mx anywhere"]) { return thing("computermouse.fill") }
        if has(["controller", "gamepad", "dualsense", "dualshock", "joy-con", "8bitdo", "手柄"]) || words.contains("xbox") {
            return thing("gamecontroller.fill")
        }
        // Everyone else's headphones: in-ear, then over-ear models, then headphones of any sort.
        if has(["buds", "earbud", "earphone", "in-ear", "耳塞"]) || lowered.hasPrefix("wf-") || words.contains("wf") {
            return worn("earbuds")
        }
        if lowered.hasPrefix("wh-") || words.contains("wh") || has(["wh-1000", "quietcomfort", "qc ultra headphones", "qc45", "qc35",
                                                                    "momentum 4", "px7", "px8", "headphones 700"]) {
            return worn("headphones.over.ear")
        }
        if has(["headphone", "headset", "耳机", "耳麦"]) { return worn("headphones") }
        // Speakers and screens.
        if has(["studio display", "display", "monitor", "显示器"]) { return thing("display") }
        if words.contains("tv") || has(["电视"]) { return thing("tv.fill") }
        if has(["speaker", "soundbar", "sonos", "soundlink", "音箱", "音响", "扬声器"]) { return thing("hifispeaker.fill") }
        return nil
    }

    /// The Bluetooth class of device: the major class says what it is, the minor class narrows it.
    static func symbol(forMajorClass major: Int, minor: Int) -> String {
        switch major {
        case 0x01: return minor == 0x01 ? "desktopcomputer" : "laptopcomputer"
        case 0x02: return "iphone"
        case 0x04:
            switch minor {
            case 0x05, 0x07: return "hifispeaker.fill"
            case 0x08: return "car.fill"
            case 0x0F: return "tv.fill"
            default: return "headphones"
            }
        case 0x05:
            if minor & 0x0F == 0x01 || minor & 0x0F == 0x02 { return "gamecontroller.fill" }
            if minor & 0x0F == 0x03 { return "av.remote.fill" }
            if minor & 0x30 == 0x20 { return "computermouse.fill" }
            return "keyboard.fill"
        case 0x06: return "printer.fill"
        case 0x07: return "applewatch"
        default: return "wave.3.right"
        }
    }

    /// "Alice's AirPods Pro" → "AirPods Pro": in the narrow wings the model says more than the owner,
    /// who is nearly always you.
    static func shortName(_ name: String) -> String {
        for separator in ["’s ", "'s ", "的"] {
            guard let range = name.range(of: separator) else { continue }
            let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // Only when what's left is a model, not the second half of a name.
            if rest.count >= 3, look(forName: rest) != nil { return rest }
        }
        return name
    }
}
