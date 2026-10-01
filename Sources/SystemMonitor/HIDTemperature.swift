import Foundation
import IOKit

/// Temperature sensors through the private IOHIDEventSystemClient API (resolved with dlsym, so a
/// missing symbol simply disables this fallback). Confined to the sampler queue.
final class HIDTemperatureReader {
    struct Sensor: Equatable, Sendable {
        var name: String
        var celsius: Double
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private struct API {
        let create: CreateFn
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let getFloat: GetFloatFn
    }

    private static let kIOHIDEventTypeTemperature: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private static let api: API? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, as: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = load("IOHIDEventSystemClientCreate", as: CreateFn.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloat = load("IOHIDEventGetFloatValue", as: GetFloatFn.self) else { return nil }
        return API(create: create, setMatching: setMatching, copyServices: copyServices,
                   copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat)
    }()

    private var client: AnyObject?
    private var services: [(service: AnyObject, name: String)] = []
    private var servicesTime: Double = -.infinity

    static var isAvailable: Bool { api != nil }

    /// Reads all temperature sensors (PrimaryUsagePage 0xff00 / PrimaryUsage 5).
    func readAll() -> [Sensor] {
        guard let api = Self.api else { return [] }
        if client == nil {
            guard let c = api.create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = api.setMatching(c, matching)
            client = c
        }
        guard let client else { return [] }
        let now = monotonicSeconds()
        if services.isEmpty || now - servicesTime > 60 {
            servicesTime = now
            let list = (api.copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
            services = list.map { service in
                let name = api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
                return (service, name)
            }
        }
        var sensors: [Sensor] = []
        for (service, name) in services {
            guard let event = api.copyEvent(service, Self.kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let value = api.getFloat(event, Self.temperatureField)
            if value.isFinite { sensors.append(Sensor(name: name, celsius: value)) }
        }
        return sensors
    }

    func close() {
        services = []
        client = nil
    }
}
