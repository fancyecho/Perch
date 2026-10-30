import CoreWLAN
import Foundation
import Synchronization
import SystemConfiguration

/// Wi-Fi signal (nil without Wi-Fi, such as on Ethernet).
struct WiFiSnapshot: Equatable {
    var rssi: Int          // dBm; closer to 0 is stronger
    var noise: Int         // dBm
    var rate: Double       // current link rate, Mbps
    var channel: Int
    var band: String       // "2.4 GHz" / "5 GHz" / "6 GHz"

    /// Signal strength from 0 to 1, for the bars of the Wi-Fi symbol.
    var strength: Double { min(max(Double(rssi + 90) / 40, 0), 1) }
}

/// Round-trip latency in milliseconds, nil without a reply.
nonisolated struct LatencySnapshot: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        var name: String
        var host: String
        var milliseconds: Double?
    }

    var gateway: Double?
    var targets: [Target]

    /// Internet latency is the fastest of a few public DNS servers: all anycast, so in any country they reach a
    /// nearby node, and one being blocked locally doesn't skew the result.
    var internet: Double? { targets.compactMap(\.milliseconds).min() }
}

enum WiFiSampler {
    static func sample() -> WiFiSnapshot? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(), interface.rssiValue() != 0 else { return nil }
        let band: String = switch interface.wlanChannel()?.channelBand {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: ""
        }
        return WiFiSnapshot(rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
                            rate: interface.transmitRate(), channel: interface.wlanChannel()?.channelNumber ?? 0, band: band)
    }
}

/// Latency by ICMP: the router (many don't answer ping; then it isn't shown) and a few anycast public DNS servers.
nonisolated enum LatencySampler {
    static let publicTargets = [("Cloudflare", "1.1.1.1"), ("Google", "8.8.8.8"), ("Quad9", "9.9.9.9"), ("AliDNS", "223.5.5.5")]

    /// Blocking; every target in parallel, about a second at most.
    static func sample() -> LatencySnapshot {
        let hosts = [gatewayAddress()] + publicTargets.map { Optional($0.1) }
        let replies = Mutex([Double?](repeating: nil, count: hosts.count))
        DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
            guard let host = hosts[index] else { return }
            let value = Pinger.ping(host)
            replies.withLock { $0[index] = value }
        }
        let results = replies.withLock { $0 }
        let targets = publicTargets.enumerated().map { index, target in
            LatencySnapshot.Target(name: target.0, host: target.1, milliseconds: results[index + 1])
        }
        return LatencySnapshot(gateway: results[0], targets: targets)
    }

    private static func gatewayAddress() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Perch" as CFString, nil, nil),
              let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return info["Router"] as? String
    }
}

/// ICMP echo without admin rights (macOS lets ordinary processes send ICMP over SOCK_DGRAM).
nonisolated enum Pinger {
    static func ping(_ address: String, timeout: TimeInterval = 1) -> Double? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        let sequence = UInt16.random(in: 1...UInt16.max)
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8   // echo request
        packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xff)
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xff)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }

        let deadline = start + UInt64(timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { return nil }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            // The reply may start with an IPv4 header; skip it.
            let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0f) * 4 : 0
            guard count >= offset + 8 else { continue }
            let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            if buffer[offset] == 0, replySequence == sequence {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[index]) << 8 | UInt32(index + 1 < bytes.count ? bytes[index + 1] : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
