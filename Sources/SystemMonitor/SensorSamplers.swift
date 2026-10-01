import Foundation
import IOKit
import IOKit.ps
import OneSwitchCore

/// SMC-backed power and temperature readings plus the HID temperature fallback and battery info.
/// Owns the SMC connection. Confined to the sampler queue.
final class SensorSampler {
    /// Accepted temperature range; values outside are sensor glitches (e.g. -4 / 0 on Apple Silicon).
    static let validTemperature: ClosedRange<Double> = 10...120
    static let powerKeys = ["PSTR", "PDTR", "PPBR"]

    struct KeyDescriptor: Equatable, Sendable {
        var key: UInt32
        var name: String
    }

    private var smc: SMCClient?
    private var smcUnavailable = false
    /// Cached key lists (survive closing / reopening the connection).
    private var cpuKeys: [KeyDescriptor]?
    private var gpuKeys: [KeyDescriptor]?
    private var powerKey: String??
    private let hid = HIDTemperatureReader()
    private var hidOnly = false
    /// Whether HID exposes GPU sensors (nil = not probed yet); avoids a HID pass every tick when only
    /// the GPU group is missing and HID cannot provide it either.
    private var hidHasGPU: Bool?
    /// Last plausible reading per key. Apple Silicon sensors occasionally return junk for a single read
    /// (e.g. a whole group reads 0 / -4 at once); holding the last good value for a few seconds keeps
    /// the averaged sensor set — and therefore the displayed average — stable.
    private var held: [UInt32: (value: Double, time: Double)] = [:]
    static let holdSeconds: Double = 10

    /// Diagnostics of the last temperature pass (for the settings page / checks).
    private(set) var lastCPUKeysUsed: [String] = []
    private(set) var lastGPUKeysUsed: [String] = []
    private(set) var lastHIDSensorsUsed: [HIDTemperatureReader.Sensor] = []

    private func openSMC() -> SMCClient? {
        if let smc, smc.isOpen { return smc }
        guard !smcUnavailable else { return nil }
        if let client = SMCClient() {
            smc = client
            return client
        }
        smcUnavailable = true
        return nil
    }

    /// Releases the SMC connection and the HID client.
    func close() {
        smc?.close()
        smc = nil
        smcUnavailable = false
        held = [:]
        hid.close()
        hidHasGPU = nil
    }

    // MARK: Temperature

    /// Is `value` a plausible reading? Apple Silicon SMC reports whole-number sentinels (40.000, 0,
    /// -4, 4) for inactive sensors; real readings are 1/256-quantised and practically never integral.
    static func isPlausibleSMC(_ value: Double) -> Bool {
        validTemperature.contains(value) && value != value.rounded()
    }

    /// Sensor keys of M3-family chips (M3 / Pro / Max / Ultra — e.g. the MacBook Pro Mac15,6), which
    /// name their P-core and GPU die sensors "Tf…" instead of "Tp…" / "Tg…". Other generations use "Tf…"
    /// for unrelated sensors (on the M4 Max these keys exist and read 33–63 °C), so they are only added
    /// on M3 — or, for the GPU, when the chip is unknown and the SMC has no "Tg" keys at all.
    static let m3CPUKeys = ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    static let m3GPUKeys = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]

    static func isCPUKey(_ name: String) -> Bool { name.hasPrefix("Tp") || name.hasPrefix("Te") }
    static func isGPUKey(_ name: String) -> Bool { name.hasPrefix("Tg") }

    /// Apple Silicon generation of this Mac ("Apple M3 Pro" → 3), nil on Intel / when unknown.
    static let chipGeneration: Int? = sysctlString("machdep.cpu.brand_string").flatMap(chipGeneration(brand:))

    /// Parses the generation from a CPU brand string: "Apple M4 Max" → 4, "Apple M3" → 3, Intel → nil.
    static func chipGeneration(brand: String) -> Int? {
        guard let range = brand.range(of: "Apple M") else { return nil }
        let digits = brand[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    /// Which SMC keys make up the CPU and GPU groups. `discovered` are the enumerated 'flt ' keys with a
    /// "Tp" / "Te" / "Tg" prefix; `hasFloatKey` tells whether an extra (fixed-name) key exists as 'flt '.
    /// Pure (exposed for checks).
    static func keyPlan(generation: Int?, discovered: [String], hasFloatKey: (String) -> Bool) -> (cpu: [String], gpu: [String]) {
        var cpu = discovered.filter(isCPUKey)
        var gpu = discovered.filter(isGPUKey)
        if generation == 3 {
            cpu += m3CPUKeys.filter { !cpu.contains($0) && hasFloatKey($0) }
        }
        if generation == 3 || (generation == nil && gpu.isEmpty) {
            gpu += m3GPUKeys.filter { !gpu.contains($0) && hasFloatKey($0) }
        }
        return (cpu, gpu)
    }

    func sampleTemperature() -> TemperatureReading? {
        var cpu: [Double] = [], gpu: [Double] = []
        var cpuSource = TemperatureReading.Source.smc, gpuSource = TemperatureReading.Source.smc
        if !hidOnly, let smc = openSMC() {
            // Enumerate once and cache — but only when the SMC answers: a failed "#KEY" read would
            // otherwise cache empty lists and switch to HID for the rest of the app's life.
            if cpuKeys == nil || gpuKeys == nil, smc.keyCount() != nil {
                let all = smc.enumerateKeys { Self.isCPUKey($0) || Self.isGPUKey($0) }
                    .filter { $0.info.typeString == "flt " }
                let plan = Self.keyPlan(generation: Self.chipGeneration, discovered: all.map(\.name)) {
                    smc.keyInfo($0)?.typeString == "flt "
                }
                // Enumerated keys keep their exact 32-bit code; the fixed M3 names are ASCII four-char codes.
                let codes = Dictionary(all.map { ($0.name, $0.key) }, uniquingKeysWith: { a, _ in a })
                cpuKeys = plan.cpu.map { KeyDescriptor(key: codes[$0] ?? SMCClient.fourCC($0), name: $0) }
                gpuKeys = plan.gpu.map { KeyDescriptor(key: codes[$0] ?? SMCClient.fourCC($0), name: $0) }
                if plan.cpu.isEmpty && plan.gpu.isEmpty {
                    hidOnly = true // no temperature keys on this SMC: use HID from now on
                }
                AppLog.info("monitor", "SMC temperature keys: \(plan.cpu.count) CPU, \(plan.gpu.count) GPU (chip generation \(Self.chipGeneration.map(String.init) ?? "unknown"))")
            }
            let cpuValid = readValid(smc, cpuKeys ?? [])
            let gpuValid = readValid(smc, gpuKeys ?? [])
            lastCPUKeysUsed = cpuValid.map(\.name)
            lastGPUKeysUsed = gpuValid.map(\.name)
            cpu = cpuValid.map(\.value)
            gpu = gpuValid.map(\.value)
        } else {
            lastCPUKeysUsed = []
            lastGPUKeysUsed = []
        }
        // Fallback per group: HID PMU die sensors ("PMU tdie*") for the CPU, "GPU" sensors for the GPU.
        if cpu.isEmpty || (gpu.isEmpty && hidHasGPU != false) {
            let allSensors = hid.readAll()
            if hidHasGPU == nil {
                // Also settled when HID reports nothing at all, so a Mac without HID sensors is not
                // polled on every pass (re-probed after close()).
                hidHasGPU = allSensors.contains { $0.name.localizedCaseInsensitiveContains("GPU") }
            }
            let sensors = allSensors.filter { Self.validTemperature.contains($0.celsius) }
            var used: [HIDTemperatureReader.Sensor] = []
            if cpu.isEmpty {
                let s = sensors.filter { $0.name.localizedCaseInsensitiveContains("tdie") }
                cpu = s.map(\.celsius)
                cpuSource = .hid
                used += s
            }
            if gpu.isEmpty {
                let s = sensors.filter { $0.name.localizedCaseInsensitiveContains("GPU") }
                gpu = s.map(\.celsius)
                gpuSource = .hid
                used += s
            }
            lastHIDSensorsUsed = used
        } else {
            lastHIDSensorsUsed = []
        }
        guard !cpu.isEmpty || !gpu.isEmpty else { return nil }
        return Self.reading(cpu: cpu, gpu: gpu, source: cpu.isEmpty ? gpuSource : cpuSource)
    }

    private func readValid(_ smc: SMCClient, _ keys: [KeyDescriptor]) -> [(name: String, value: Double)] {
        let now = monotonicSeconds()
        var out: [(String, Double)] = []
        for k in keys {
            if let v = smc.readNumber(k.key), Self.isPlausibleSMC(v) {
                held[k.key] = (v, now)
                out.append((k.name, v))
            } else if let h = held[k.key], now - h.time <= Self.holdSeconds {
                out.append((k.name, h.value))
            }
        }
        return out
    }

    /// Pure aggregation (exposed for checks).
    static func reading(cpu: [Double], gpu: [Double], source: TemperatureReading.Source) -> TemperatureReading {
        func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        return TemperatureReading(cpuAverage: avg(cpu), cpuMax: cpu.max(), gpuAverage: avg(gpu), gpuMax: gpu.max(),
                                  cpuSensorCount: cpu.count, gpuSensorCount: gpu.count, source: source)
    }

    // MARK: Power

    func samplePower() -> PowerReading? {
        var watts: Double?
        var source: String?
        if let smc = openSMC() {
            if powerKey == nil {
                let found = Self.powerKeys.first { smc.keyInfo($0) != nil }
                // "No power key" is only remembered when the SMC itself answers (not a failed call).
                if found != nil || smc.keyCount() != nil { powerKey = .some(found) }
            }
            if let key = powerKey ?? nil, let v = smc.readNumber(key), v.isFinite, v >= 0, v < 2000 {
                watts = v
                source = key
            }
        }
        let battery = AppEnvironment.isLaptop ? Self.readBattery() : nil
        guard watts != nil || battery != nil else { return nil }
        return PowerReading(systemWatts: watts, sourceKey: source, battery: battery)
    }

    /// Battery state from IOPowerSources plus AppleSmartBattery (voltage × amperage, adapter watts).
    static func readBattery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var reading: BatteryReading?
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maxCap = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let charging = (desc[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[minutesKey] as? NSNumber)?.intValue
            reading = BatteryReading(level: maxCap > 0 ? min(1, max(0, current / maxCap)) : 0,
                                     isCharging: charging, onAC: onAC, batteryWatts: nil, adapterWatts: nil,
                                     minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
            break
        }
        guard var battery = reading else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> NSNumber? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            }
            if let mv = number("Voltage")?.int64Value,
               let ma = (number("InstantAmperage") ?? number("Amperage"))?.int64Value {
                battery.batteryWatts = Double(mv) * Double(ma) / 1_000_000
            }
            if let adapter = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let w = (adapter["Watts"] as? NSNumber)?.doubleValue, w > 0 {
                battery.adapterWatts = w
            }
        }
        return battery
    }
}
