import Foundation
import Combine

/// A JSON-encoded, UserDefaults-backed settings value that SwiftUI can bind to.
///
/// ```swift
/// struct AwakeSettings: Codable, Equatable { var scheduleEnabled = true; var startMinute = 8 * 60 }
/// let store = SettingsStore(key: "awake.settings", defaultValue: AwakeSettings())
/// Toggle("自动计划", isOn: $store.value.scheduleEnabled)
/// store.$value.sink { newValue in ... }   // react to changes
/// ```
///
/// Schema evolution: when stored JSON no longer decodes (e.g. a field was added), the stored keys are
/// merged over the encoded default value (top level first, then recursively for nested structs), so
/// existing user choices survive new fields. Arrays are taken as stored, so element types of stored arrays (e.g. a list of
/// folder configs) must decode tolerantly themselves (`decodeIfPresent` with defaults). Data that still
/// cannot be decoded is kept under "<key>.unreadable" instead of being silently overwritten.
@MainActor
public final class SettingsStore<Value: Codable & Equatable>: ObservableObject {
    @Published public var value: Value {
        didSet {
            guard value != oldValue else { return }
            persist()
        }
    }

    public let key: String
    public let defaultValue: Value
    private let defaults: UserDefaults

    public init(key: String, defaultValue: Value, defaults: UserDefaults = AppEnvironment.defaults) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
        self.value = Self.load(key: key, defaultValue: defaultValue, defaults: defaults)
    }

    /// Mutate the value in place (single publish / persist).
    public func update(_ body: (inout Value) -> Void) {
        var copy = value
        body(&copy)
        value = copy
    }

    public func resetToDefault() { value = defaultValue }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            AppLog.error("settings", "failed to encode \(key): \(error)")
        }
    }

    private static func load(key: String, defaultValue: Value, defaults: UserDefaults) -> Value {
        guard let data = defaults.data(forKey: key) else { return defaultValue }
        if let v = try? JSONDecoder().decode(Value.self, from: data) { return v }
        // Merge stored keys over defaults to survive added / removed fields. Stored keys that are absent
        // from the encoded default are kept too: optionals whose default is nil (e.g. a hotkey) are
        // omitted by the encoder but must not be lost. Keys the type no longer declares are ignored by
        // the decoder.
        // First the top level only (stored fields win as a whole), then recursively into nested objects
        // (a nested struct that gained a field). The recursive merge is only a fallback: for a
        // dictionary or an enum with associated values it could mix stored and default entries.
        if let stored = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let defData = try? JSONEncoder().encode(defaultValue),
           let defObject = try? JSONSerialization.jsonObject(with: defData, options: [.fragmentsAllowed]) {
            for deep in [false, true] {
                let merged = mergeJSON(stored: stored, over: defObject, deep: deep)
                if let mergedData = try? JSONSerialization.data(withJSONObject: merged, options: [.fragmentsAllowed]),
                   let v = try? JSONDecoder().decode(Value.self, from: mergedData) {
                    AppLog.info("settings", "migrated settings for \(key)\(deep ? " (nested)" : "")")
                    return v
                }
            }
        }
        // Keep the unreadable data (a newer / older build may still understand it) — the first change
        // made with the defaults would otherwise overwrite it for good.
        defaults.set(data, forKey: key + ".unreadable")
        AppLog.warning("settings", "could not decode \(key); using defaults (old data kept as \(key).unreadable)")
        return defaultValue
    }

    /// Stored JSON merged over the default JSON: objects merge key by key (recursively when `deep`),
    /// anything else (arrays, scalars, type mismatches) takes the stored value.
    static func mergeJSON(stored: Any, over fallback: Any, deep: Bool) -> Any {
        guard let storedObject = stored as? [String: Any], let fallbackObject = fallback as? [String: Any] else {
            return stored
        }
        var result = fallbackObject
        for (k, v) in storedObject {
            if deep, let nestedFallback = fallbackObject[k] {
                result[k] = mergeJSON(stored: v, over: nestedFallback, deep: true)
            } else {
                result[k] = v
            }
        }
        return result
    }
}
