import CoreGraphics
import Foundation

/// Fixed-capacity ring buffer of samples (oldest are dropped first).
public struct SampleHistory: Equatable, Sendable {
    public let capacity: Int
    private var storage: [Double] = []
    /// Index of the oldest element once the buffer is full.
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ value: Double) {
        let v = value.isFinite ? value : 0
        if storage.count < capacity {
            storage.append(v)
        } else {
            storage[head] = v
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Samples in chronological order (oldest first).
    public var values: [Double] {
        guard storage.count == capacity, head != 0 else { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// The newest `n` samples, oldest first.
    public func suffix(_ n: Int) -> [Double] {
        Array(values.suffix(max(0, n)))
    }

    public var last: Double? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity ? storage.last : storage[(head + capacity - 1) % capacity]
    }

    public var maxValue: Double? { storage.max() }
    public var minValue: Double? { storage.min() }
}

/// Sparkline geometry shared by the menu-bar renderer and the SwiftUI detail view.
public enum Sparkline {
    /// Vertical range for a series: fixed 0…1 for fractions, 0…max (with a floor) for rates and power,
    /// a padded min…max window for temperatures.
    public enum Scale: Equatable, Sendable {
        case unit
        case zeroBased(floor: Double)
        case window(minSpan: Double)
    }

    public static func range(for values: [Double], scale: Scale) -> ClosedRange<Double> {
        switch scale {
        case .unit:
            return 0...1
        case .zeroBased(let floor):
            let m = max(floor, values.max() ?? 0)
            return 0...(m * 1.1)
        case .window(let minSpan):
            guard let lo = values.min(), let hi = values.max() else { return 0...max(1, minSpan) }
            let span = max(minSpan, hi - lo)
            let mid = (lo + hi) / 2
            return (mid - span / 2 - span * 0.1)...(mid + span / 2 + span * 0.1)
        }
    }

    /// Values mapped to 0…1 within `range` (clamped).
    public static func normalize(_ values: [Double], range: ClosedRange<Double>) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return values.map { _ in 0 } }
        return values.map { min(1, max(0, ($0 - range.lowerBound) / span)) }
    }

    /// Points for normalized values (0…1) in a `width` × `height` box with y growing upwards.
    /// The newest sample sits on the right edge; `capacity` samples span the full width, so a
    /// partially filled history grows in from the right.
    public static func points(normalized: [Double], capacity: Int, width: Double, height: Double) -> [CGPoint] {
        guard !normalized.isEmpty, capacity > 1 else {
            return normalized.isEmpty ? [] : [CGPoint(x: width, y: normalized[0] * height)]
        }
        let step = width / Double(capacity - 1)
        let values = normalized.suffix(capacity)
        let n = values.count
        return values.enumerated().map { i, v in
            CGPoint(x: width - Double(n - 1 - i) * step, y: min(1, max(0, v)) * height)
        }
    }
}
