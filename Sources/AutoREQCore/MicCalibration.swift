import Foundation

/// The frequency response of a measurement microphone.
/// The app subtracts it from every measurement, so the result shows the speaker and the room only.
public struct MicCalibration: Codable, Hashable, Sendable, Identifiable {
    public struct Point: Codable, Hashable, Sendable {
        public var frequency: Double
        public var gainDB: Double
        public var phaseDeg: Double?
        public init(_ frequency: Double, _ gainDB: Double, phaseDeg: Double? = nil) {
            self.frequency = frequency; self.gainDB = gainDB; self.phaseDeg = phaseDeg
        }
    }

    public var id: String { name }
    public var name: String
    /// Where the data came from: a file name, or the publisher of a typical curve.
    public var source: String
    /// True for an average curve of a mic model. A per-unit file from the maker is more accurate.
    public var isTypical: Bool
    public var serial: String?
    public var sensitivityDB: Double?
    public var points: [Point]

    public init(name: String, source: String, isTypical: Bool, serial: String? = nil, sensitivityDB: Double? = nil, points: [Point]) {
        self.name = name; self.source = source; self.isTypical = isTypical
        self.serial = serial; self.sensitivityDB = sensitivityDB
        self.points = points.sorted { $0.frequency < $1.frequency }
    }

    public var frequencyRange: ClosedRange<Double>? {
        guard let a = points.first?.frequency, let b = points.last?.frequency else { return nil }
        return a...b
    }

    /// The mic deviation in dB at `f`. The curve is linear on a log-frequency axis and flat outside the data.
    public func gain(at f: Double) -> Double { interpolate(f) { $0.gainDB } }

    /// The mic phase in degrees at `f`, or 0 when the file has no phase.
    public func phase(at f: Double) -> Double {
        guard points.contains(where: { $0.phaseDeg != nil }) else { return 0 }
        return interpolate(f) { $0.phaseDeg ?? 0 }
    }

    private func interpolate(_ f: Double, _ value: (Point) -> Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.frequency { return value(first) }
        if f >= last.frequency { return value(last) }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].frequency <= f { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let t = (log(f) - log(a.frequency)) / (log(b.frequency) - log(a.frequency))
        return value(a) + (value(b) - value(a)) * t
    }

    /// Reads a REW / miniDSP style calibration file.
    ///
    /// The format: comment lines start with `*`, `"`, `#` or `;`. A header can hold
    /// `Sens Factor =-1.23dB` and `SERNO: 1234567`. Each data line holds the frequency in Hz,
    /// the deviation in dB, and an optional phase in degrees, separated by spaces, tabs or commas.
    public static func parse(_ text: String, name: String) -> MicCalibration? {
        var sens: Double?, serial: String?
        var pts: [Point] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if let r = lower.range(of: "sens factor") {
                let tail = line[r.upperBound...].drop { $0 == " " || $0 == "=" || $0 == ":" }
                sens = Double(tail.prefix { "+-.0123456789".contains($0) })
            }
            if let r = line.range(of: "SERNO:", options: .caseInsensitive) {
                serial = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \"")).components(separatedBy: CharacterSet(charactersIn: " ,\"")).first
            }
            if let c = line.first, "*\"#;".contains(c) { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" }).map { Double($0) }
            guard cols.count >= 2, let f = cols[0], let g = cols[1], f > 0, f.isFinite, g.isFinite else { continue }
            let p = cols.count > 2 ? cols[2] : nil
            pts.append(Point(f, g, phaseDeg: p))
        }
        guard pts.count >= 2 else { return nil }
        return MicCalibration(name: name, source: name, isTypical: false, serial: serial, sensitivityDB: sens, points: pts)
    }

    /// Writes the calibration in the REW format, so it can be read back or used in REW.
    public func encode() -> String {
        var s = "* \(name) — \(source)\n"
        if let sensitivityDB { s += String(format: "\"Sens Factor =%.2fdB", sensitivityDB) + (serial.map { ", SERNO: \($0)" } ?? "") + "\"\n" }
        for p in points {
            s += String(format: "%.3f\t%.3f", p.frequency, p.gainDB) + (p.phaseDeg.map { String(format: "\t%.2f", $0) } ?? "") + "\n"
        }
        return s
    }
}

extension Response {
    /// Removes the mic's own response: the gain and, if the file has one, the phase.
    public func removing(mic: MicCalibration) -> Response {
        var r = self
        for (i, f) in FrequencyGrid.frequencies.enumerated() {
            r.magnitudeDB[i] -= mic.gain(at: f)
            r.phaseDeg[i] = wrapDegrees(r.phaseDeg[i] - mic.phase(at: f))
        }
        return r
    }
}

extension MicCalibration {
    /// Typical curves that ship with the app. Each one names its published source.
    ///
    /// No maker publishes a generic file for the common measurement mics (UMIK-1/2, EMM-6, UMM-6,
    /// ECM8000, XREF 20): their files are per serial number, so the user imports them.
    ///
    /// The iPhone curves are the pressure response of the bottom mic of one unit, measured by
    /// Faber Acoustical in an anechoic chamber over a wired connection with measurement mode on.
    /// Faber publishes graphs only. The values here were read from those graphs by eye, about
    /// ±0.5 dB above 100 Hz and ±1–2 dB below 50 Hz. The curves stop at 5 kHz, because above 10 kHz
    /// the published units differ by more than 5 dB. Above 5 kHz the app applies no correction.
    public static let builtIn: [MicCalibration] = [
        MicCalibration(
            name: "iPhone 17 Pro (approx., 30 Hz–5 kHz)",
            source: "Faber Acoustical, \"Measured iPhone 17 Pro microphone frequency response\", 2025-09-25, read from the graph",
            isTypical: true,
            points: [.init(30, -7), .init(40, -4), .init(50, -3), .init(60, -2.4), .init(80, -1.7), .init(100, -1.2),
                     .init(200, -0.6), .init(500, -0.2), .init(1000, 0), .init(2000, 0), .init(5000, 0)]),
        MicCalibration(
            name: "iPhone 18 Pro (approx., 30 Hz–5 kHz)",
            source: "Faber Acoustical, \"Measured iPhone 18 Pro microphone frequency response\", 2026-10-05, read from the graph",
            isTypical: true,
            points: [.init(30, -14), .init(40, -7.5), .init(50, -4.7), .init(60, -2.8), .init(80, -1.4), .init(100, -1.0),
                     .init(200, -0.3), .init(500, 0), .init(1000, 0), .init(2000, 0), .init(5000, -0.2)]),
    ]
}
