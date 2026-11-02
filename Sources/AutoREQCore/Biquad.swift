import Foundation

/// The seven filter types of one parametric EQ band.
public enum FilterType: String, Codable, CaseIterable, Sendable {
    case peaking = "Peaking"
    case lowShelf = "Low Shelf"
    case highShelf = "High Shelf"
    case lowPass = "Low Pass"
    case highPass = "High Pass"
    case notch = "Notch"
    case allPass = "All Pass"

    /// The REW "Filter Settings" code for this type.
    public var rewCode: String {
        switch self {
        case .peaking: "PK"
        case .lowShelf: "LSQ"
        case .highShelf: "HSQ"
        case .lowPass: "LPQ"
        case .highPass: "HPQ"
        case .notch: "NO"
        case .allPass: "AP"
        }
    }
}

/// One parametric EQ band. The ranges follow the Omnissiah manual: 20–20,000 Hz, ±18 dB, Q 0.1–10.
public struct EQBand: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool

    public static let frequencyRange = 20.0...20_000.0
    public static let gainRange = -18.0...18.0
    public static let qRange = 0.1...10.0

    public init(type: FilterType = .peaking, frequency: Double = 1000, gainDB: Double = 0, q: Double = 1, enabled: Bool = true) {
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
    }

    public func coefficients(sampleRate: Double) -> BiquadCoefficients {
        BiquadCoefficients(type: type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }
}

/// Normalised biquad coefficients (a0 = 1). The formulas are the RBJ Audio EQ Cookbook.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public init(type: FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let f = min(max(frequency, 1), sampleRate * 0.49)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 0.01))
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch type {
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        case .notch:
            b0 = 1; b1 = -2 * cw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cw + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cw)
            b2 = a * ((a + 1) - (a - 1) * cw - s)
            a0 = (a + 1) + (a - 1) * cw + s
            a1 = -2 * ((a - 1) + (a + 1) * cw)
            a2 = (a + 1) + (a - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cw + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cw)
            b2 = a * ((a + 1) + (a - 1) * cw - s)
            a0 = (a + 1) - (a - 1) * cw + s
            a1 = 2 * ((a - 1) - (a + 1) * cw)
            a2 = (a + 1) - (a - 1) * cw - s
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// The complex frequency response at `frequency`.
    public func response(at frequency: Double, sampleRate: Double) -> Complex {
        let w = 2 * Double.pi * frequency / sampleRate
        let z1 = Complex(cos(-w), sin(-w))
        let z2 = z1 * z1
        let num = Complex(b0, 0) + z1 * b1 + z2 * b2
        let den = Complex(1, 0) + z1 * a1 + z2 * a2
        return num / den
    }

    /// The magnitude in dB at `frequency`. This form needs no complex division.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), c2 = cos(2 * w)
        let num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * c1 + 2 * b0 * b2 * c2
        let den = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * c1 + 2 * a2 * c2
        return 10 * log10(max(num, 1e-30) / max(den, 1e-30))
    }
}

/// Transposed direct form II state for one channel. The render thread owns it.
public struct BiquadState: Sendable {
    public var c: BiquadCoefficients
    var z1: Double = 0
    var z2: Double = 0

    public init(_ c: BiquadCoefficients) { self.c = c }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// A minimal complex number. Foundation has none.
public struct Complex: Sendable, Equatable, Codable {
    public var re: Double
    public var im: Double
    public init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
    public static let zero = Complex(0, 0)
    public static let one = Complex(1, 0)

    public static func polar(_ mag: Double, _ phase: Double) -> Complex { Complex(mag * cos(phase), mag * sin(phase)) }

    public var magnitude: Double { (re * re + im * im).squareRoot() }
    public var magnitudeSquared: Double { re * re + im * im }
    public var phase: Double { atan2(im, re) }
    public var conjugate: Complex { Complex(re, -im) }

    public static func + (l: Complex, r: Complex) -> Complex { Complex(l.re + r.re, l.im + r.im) }
    public static func - (l: Complex, r: Complex) -> Complex { Complex(l.re - r.re, l.im - r.im) }
    public static func * (l: Complex, r: Complex) -> Complex { Complex(l.re * r.re - l.im * r.im, l.re * r.im + l.im * r.re) }
    public static func * (l: Complex, r: Double) -> Complex { Complex(l.re * r, l.im * r) }
    public static func / (l: Complex, r: Complex) -> Complex {
        let d = max(r.magnitudeSquared, 1e-300)
        return Complex((l.re * r.re + l.im * r.im) / d, (l.im * r.re - l.re * r.im) / d)
    }
    public static func += (l: inout Complex, r: Complex) { l = l + r }
}
