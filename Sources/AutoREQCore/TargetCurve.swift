import Foundation

/// A target curve. It is a shape only, not an absolute level.
/// The curve is linear in dB between points on a log-frequency axis, and flat outside the end points.
public struct TargetCurve: Codable, Hashable, Sendable, Identifiable {
    public struct Point: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var frequency: Double
        public var gainDB: Double
        public init(_ frequency: Double, _ gainDB: Double) { self.frequency = frequency; self.gainDB = gainDB }
    }

    public var id: String { name }
    public var name: String
    public var points: [Point]

    public static let frequencyRange = 20.0...20_000.0
    public static let gainRange = -12.0...12.0

    public init(name: String, points: [Point]) {
        self.name = name
        self.points = points
    }

    public func gain(at f: Double) -> Double {
        let p = points.sorted { $0.frequency < $1.frequency }
        guard let first = p.first, let last = p.last else { return 0 }
        if f <= first.frequency { return first.gainDB }
        if f >= last.frequency { return last.gainDB }
        for k in 1..<p.count where f <= p[k].frequency {
            let a = p[k - 1], b = p[k]
            let t = (log(f) - log(a.frequency)) / (log(b.frequency) - log(a.frequency))
            return a.gainDB + (b.gainDB - a.gainDB) * t
        }
        return last.gainDB
    }

    public var gridValues: [Double] { FrequencyGrid.frequencies.map(gain(at:)) }

    // The preset shapes are approximations of the manual's descriptions. The manual gives no numbers.
    public static let houseFlat = TargetCurve(name: "House Flat", points: [.init(20, 4), .init(60, 4), .init(200, 1.5), .init(1000, 0), .init(20_000, 0)])
    public static let absoluteFlat = TargetCurve(name: "Absolute Flat", points: [.init(20, 0), .init(20_000, 0)])
    public static let nCurve = TargetCurve(name: "N Curve", points: [.init(20, 6), .init(100, 5), .init(400, 1), .init(1000, 0), .init(10_000, -2), .init(20_000, -4)])
    public static let hCurve = TargetCurve(name: "H Curve", points: [.init(20, 3), .init(80, 4), .init(250, 0), .init(2500, 1.5), .init(5000, 1), .init(20_000, -1)])
    public static let dCurve = TargetCurve(name: "D Curve", points: [.init(20, 2), .init(200, 1), .init(1000, 0), .init(4000, -1), .init(10_000, -3.5), .init(20_000, -6)])
    public static let custom = TargetCurve(name: "Custom", points: [.init(30, 5), .init(80, 4), .init(200, 2), .init(1000, 0), .init(20_000, 0)])

    public static let presets: [TargetCurve] = [houseFlat, absoluteFlat, nCurve, hCurve, dCurve]
}
