// OpenVision - PhoneStatusTool.swift
// AUR-794: the phone's own state, spoken from the glasses — «сколько батареи?», «какой вайфай?».
// The phone-body plan (docs/product/2026-08-20-phone-body-plan.md §2) asks for battery + charging,
// the Wi-Fi network (and whether the link is "expensive" / cellular), the thermal state, free
// storage, and the glasses battery IF the DAT SDK exposes it.
//
// Everything here is read from a stable Apple API — no permission is needed for battery, thermal,
// storage or the interface type, so the tool has NO `permissionKind`: gating the whole call on a
// permission would make «сколько батареи?» fail for want of a location prompt. The ONE part that
// does need something (the Wi-Fi *name*) reports its own miss reason inline, in the AUR-836 spirit:
// a missing permission is a STATE the brain can explain, not a failure of the call.
//
// What is deliberately absent rather than faked:
//   • the Wi-Fi SSID when Location is not granted (`ssidMiss: location_permission`) or when the
//     `com.apple.developer.networking.wifi-info` entitlement is not on the build
//     (`ssidMiss: entitlement`) — `NEHotspotNetwork.fetchCurrent()` returns nil in both cases, and
//     the two are told apart by the location status we read ourselves.
//   • the GLASSES battery. Checked against the pinned SDK (meta-wearables-dat-ios 0.4.0,
//     MWDATCore.swiftinterface): `public struct DeviceState { public let batteryLevel: Int; … }`
//     exists, and so does `DeviceStateSession` — but that class publishes only `state:
//     SessionState` + `start()`/`stop()`; NOTHING in the public interface hands a `DeviceState`
//     back (no accessor, no listener, no stream), and `WearablesInterface` has no battery member
//     either. So on 0.4.0 the number is unreachable and the tool says so
//     (`glassesBatteryMiss: "dat_0.4.0_no_public_accessor"`) instead of inventing one. When a later
//     DAT exposes it, `GlassesManager.glassesBatteryPercent` is the single place to fill in.

import Foundation
import UIKit
import Network
import NetworkExtension
import CoreLocation

// MARK: - Snapshot

/// Everything the tool can honestly say about the phone right now. `nil` = we do not know, and the
/// matching `…Miss` field says why.
struct PhoneStatusSnapshot: Equatable {

    enum Charging: String, Equatable { case charging, full, unplugged, unknown }
    /// The interface the phone is actually using for data.
    enum Link: String, Equatable { case wifi, cellular, wired, other, offline }
    /// Why the Wi-Fi network NAME is absent.
    enum SSIDMiss: String, Equatable {
        case notWifi = "not_wifi"
        case locationPermission = "location_permission"
        case entitlement = "entitlement"
        case simulator = "simulator"
    }

    var batteryPercent: Int?
    var charging: Charging = .unknown
    var link: Link = .offline
    /// `NWPath.isExpensive` — cellular / personal hotspot. The plan's "expensive".
    var expensive = false
    /// `NWPath.isConstrained` — Low Data Mode.
    var constrained = false
    var ssid: String?
    var ssidMiss: SSIDMiss?
    /// `ProcessInfo.thermalState`: nominal | fair | serious | critical.
    var thermal = "nominal"
    var freeBytes: Int64?
    var glassesBatteryPercent: Int?
    /// Why the glasses battery is absent (never a made-up number).
    var glassesBatteryMiss: String?

    /// The line the brain gets back. Compact, factual, English keys — the model speaks it in
    /// whatever language the wearer is using (the plan's «сколько батареи?» is answered in Russian
    /// by the model, not by a hard-coded string here).
    var spoken: String {
        var parts: [String] = []
        if let batteryPercent {
            let suffix: String
            switch charging {
            case .charging: suffix = ", charging"
            case .full: suffix = ", charged"
            case .unplugged: suffix = ", on battery"
            case .unknown: suffix = ""
            }
            parts.append("battery \(batteryPercent)%\(suffix)")
        } else {
            parts.append("battery unknown")
        }
        switch link {
        case .wifi:
            if let ssid {
                parts.append("Wi-Fi \"\(ssid)\"")
            } else {
                parts.append("Wi-Fi (network name unavailable: \(ssidMiss?.rawValue ?? "unknown"))")
            }
        case .cellular: parts.append("cellular")
        case .wired: parts.append("wired")
        case .other: parts.append("connected")
        case .offline: parts.append("offline")
        }
        if expensive { parts.append("expensive link") }
        if constrained { parts.append("low data mode") }
        if thermal != "nominal" { parts.append("thermal \(thermal)") }
        if let freeBytes { parts.append("\(PhoneStatusSnapshot.gb(freeBytes)) free") }
        if let glassesBatteryPercent {
            parts.append("glasses battery \(glassesBatteryPercent)%")
        } else if let glassesBatteryMiss {
            parts.append("glasses battery unavailable (\(glassesBatteryMiss))")
        }
        return parts.joined(separator: ", ")
    }

    static func gb(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
}

// MARK: - Reader (the real device; the tool takes it behind a closure so tests never touch it)

enum PhoneStatusReader {

    /// One full read. Every part is independently bounded so a slow Wi-Fi / path answer can never
    /// hold the 8-s tool budget hostage — a missing part comes back absent, with its reason.
    static func read() async -> PhoneStatusSnapshot {
        var s = PhoneStatusSnapshot()

        let (percent, charging) = await battery()
        s.batteryPercent = percent
        s.charging = charging

        let p = await path()
        s.link = p.link
        s.expensive = p.expensive
        s.constrained = p.constrained

        let (ssid, miss) = await ssid(link: p.link)
        s.ssid = ssid
        s.ssidMiss = miss

        s.thermal = thermal()
        s.freeBytes = freeBytes()

        let glasses = await MainActor.run { GlassesManager.shared.glassesBatteryPercent }
        s.glassesBatteryPercent = glasses.percent
        s.glassesBatteryMiss = glasses.miss

        return s
    }

    /// Battery monitoring is off by default and the first read right after enabling it can still be
    /// -1 — give the OS one run-loop tick before giving up.
    @MainActor
    static func battery() async -> (Int?, PhoneStatusSnapshot.Charging) {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        if device.batteryLevel < 0 {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        let level = device.batteryLevel
        let percent = level < 0 ? nil : Int((level * 100).rounded())
        let charging: PhoneStatusSnapshot.Charging
        switch device.batteryState {
        case .charging: charging = .charging
        case .full: charging = .full
        case .unplugged: charging = .unplugged
        case .unknown: charging = .unknown
        @unknown default: charging = .unknown
        }
        return (percent, charging)
    }

    struct PathRead: Equatable {
        var link: PhoneStatusSnapshot.Link = .offline
        var expensive = false
        var constrained = false
    }

    /// One-shot `NWPathMonitor`: the first update wins, the monitor is cancelled, and a 2-s cap
    /// means a wedged network stack answers "offline" instead of hanging the tool.
    static func path() async -> PathRead {
        await withCheckedContinuation { (c: CheckedContinuation<PathRead, Never>) in
            let once = OnceBox(c)
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { p in
                var r = PathRead()
                if p.status == .satisfied {
                    if p.usesInterfaceType(.wifi) { r.link = .wifi }
                    else if p.usesInterfaceType(.cellular) { r.link = .cellular }
                    else if p.usesInterfaceType(.wiredEthernet) { r.link = .wired }
                    else { r.link = .other }
                }
                r.expensive = p.isExpensive
                r.constrained = p.isConstrained
                if once.resume(r) { monitor.cancel() }
            }
            monitor.start(queue: DispatchQueue(label: "aurelia.phone.status.path"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if once.resume(PathRead()) { monitor.cancel() }
            }
        }
    }

    /// The Wi-Fi network NAME. Needs BOTH the Access-Wi-Fi-Information entitlement and Location
    /// permission; `NEHotspotNetwork.fetchCurrent()` just returns nil when either is missing, so we
    /// read the location status ourselves to tell the two apart and name the fix.
    static func ssid(link: PhoneStatusSnapshot.Link) async -> (String?, PhoneStatusSnapshot.SSIDMiss?) {
        guard link == .wifi else { return (nil, .notWifi) }
        #if targetEnvironment(simulator)
        return (nil, .simulator)
        #else
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return (nil, .locationPermission)
        }
        let network: NEHotspotNetwork? = await withCheckedContinuation { c in
            let once = OnceBox(c)
            NEHotspotNetwork.fetchCurrent { net in _ = once.resume(net) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = once.resume(nil) }
        }
        guard let network, !network.ssid.isEmpty else { return (nil, .entitlement) }
        return (network.ssid, nil)
        #endif
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    static func freeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Resume-once box for the callback APIs above (a `NWPathMonitor` handler fires repeatedly and a
/// double `resume` on a `CheckedContinuation` is a crash).
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    /// True when THIS call was the one that resumed.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(returning: value)
        return true
    }
}

// MARK: - Tool

/// Battery, network, thermal state and free storage — the phone talking about itself.
struct PhoneStatusTool: NativeTool {
    let name = "status"
    let description = "Read the phone's own state: battery percentage and whether it is charging, "
        + "the Wi-Fi network name, whether the connection is cellular or 'expensive', the thermal "
        + "state, free storage, and the glasses battery when the glasses SDK exposes it. Use for "
        + "questions like 'how much battery do I have', 'which Wi-Fi am I on', 'is the phone hot'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    /// No permission gate on the CALL: battery/thermal/storage/interface need none, and the one
    /// part that does (the Wi-Fi name) reports its own miss reason in the result.
    var permissionKind: String? { nil }

    /// Seam — tests hand in a snapshot, the app reads the device.
    var reader: () async -> PhoneStatusSnapshot = { await PhoneStatusReader.read() }

    init() {}
    init(reader: @escaping () async -> PhoneStatusSnapshot) { self.reader = reader }

    func execute(args: [String: Any]) async throws -> String {
        await reader().spoken
    }
}
