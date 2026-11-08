import Foundation

/// The tuning options of the room correction. The names and defaults follow the manual, chapter 13.
public struct CorrectionOptions: Codable, Hashable, Sendable {
    public enum Generations: Int, Codable, CaseIterable, Sendable, Identifiable {
        case overkill = 80, best = 50, balanced = 30, fastest = 15
        public var id: Int { rawValue }
        public var label: String { "\(String(describing: self).capitalized) (\(rawValue))" }
    }
    public enum Threshold: Double, Codable, CaseIterable, Sendable, Identifiable {
        case best = 0.10, balanced = 0.20, fastest = 0.30
        public var id: Double { rawValue }
        public var label: String { "\(String(describing: self).capitalized) (\(Int(rawValue * 100))%)" }
    }
    public enum Confidence: Double, Codable, CaseIterable, Sendable, Identifiable {
        case strict = 0.95, balanced = 0.70, relaxed = 0.50, permissive = 0.10
        public var id: Double { rawValue }
        public var label: String { "\(Int(rawValue * 100))% \(String(describing: self).capitalized)" }
    }
    public enum BoostTrust: Double, Codable, CaseIterable, Sendable, Identifiable {
        case off = 0, slight = 0.80, moderate = 0.65, maximum = 0.50
        public var id: Double { rawValue }
        public var label: String { self == .off ? "Off" : "\(String(describing: self).capitalized) (\(Int(rawValue * 100))%)" }
    }
    public enum CutTrust: Double, Codable, CaseIterable, Sendable, Identifiable {
        case slight = 0.80, moderate = 0.65, standard = 0.50, widest = 0.30
        public var id: Double { rawValue }
        public var label: String { "\(String(describing: self).capitalized) (\(Int(rawValue * 100))%)" }
    }
    public enum BoostRestraint: Double, Codable, CaseIterable, Sendable, Identifiable {
        case off = 0, gentle = 0.3, strong = 1.0
        public var id: Double { rawValue }
        public var label: String { String(describing: self).capitalized }
    }
    public enum GainEstimation: String, Codable, CaseIterable, Sendable, Identifiable {
        case targetLevelMatch = "Target Level Match"
        case minimumSummedError = "Minimum Summed Error (Least Squares)"
        case matchedAmplitude = "Matched Amplitude (RMS)"
        public var id: String { rawValue }
    }
    public enum DelayEstimation: String, Codable, CaseIterable, Sendable, Identifiable {
        case minimumPhaseError = "Minimum Phase Error (Least Squares)"
        case crossCorrelation = "Cross Correlation Peak (GCC-PHAT)"
        public var id: String { rawValue }
    }
    public enum TimeAlign: String, Codable, CaseIterable, Sendable, Identifiable {
        case subwooferOnly = "Subwoofer only", allSpeakers = "All speakers"
        public var id: String { rawValue }
    }

    public var generations: Generations = .balanced
    public var threshold: Threshold = .best
    public var confidence: Confidence = .balanced
    public var filterCount: Int = 24
    public var boostTrust: BoostTrust = .slight
    public var cutTrust: CutTrust = .standard
    public var boostRestraint: BoostRestraint = .gentle
    public var gainEstimation: GainEstimation = .targetLevelMatch
    public var delayEstimation: DelayEstimation = .minimumPhaseError
    public var timeAlign: TimeAlign = .subwooferOnly
    /// The largest boost of one filter. The manual allows +18 dB per band; room correction keeps boosts smaller.
    public var maxBoostDB: Double = 9
    public var quickPositions: Int = 1
    public var fullPositions: Int = 3
    /// The phase correction pass is optional in the stored state, so older state files still decode.
    public var phaseCorrectionStored: Bool?
    /// Adds all-pass filters that align the phase of the subs and the tops at the crossover. It is off by default.
    public var phaseCorrection: Bool { get { phaseCorrectionStored ?? false } set { phaseCorrectionStored = newValue } }

    public init() {}
}

/// Fits peaking filters to bring one channel's response to the target.
///
/// Step 1 places filters one at a time at the worst weighted error.
/// Step 2 runs a (1 + λ) evolution strategy for the set number of generations, as the manual's "generations" suggest.
public struct EQOptimizer {
    public struct Progress: Sendable {
        public var generation: Int
        public var totalGenerations: Int
        public var errorDB: Double
        public var filters: [EQBand]
    }

    let indices: [Int]
    let freqs: [Double]
    let measured: [Double]
    let target: [Double]
    let coherence: [Double]
    let weights: [Double]
    let options: CorrectionOptions
    let sampleRate: Double
    let range: ClosedRange<Double>

    /// - Parameters:
    ///   - measured: The magnitude in dB on `FrequencyGrid`, with any crossover already applied.
    ///   - target: The target in dB on `FrequencyGrid`, with the level offset already applied.
    ///   - range: The frequency range to correct.
    public init(measured: [Double], target: [Double], coherence: [Double], range: ClosedRange<Double>, options: CorrectionOptions, sampleRate: Double) {
        let idx = FrequencyGrid.frequencies.indices.filter { range.contains(FrequencyGrid.frequencies[$0]) }
        indices = idx
        freqs = idx.map { FrequencyGrid.frequencies[$0] }
        self.measured = idx.map { measured[$0] }
        self.target = idx.map { target[$0] }
        self.coherence = idx.map { coherence[$0] }
        let theta = options.confidence.rawValue
        weights = idx.map { i in
            let c = coherence[i]
            return c >= theta ? 1 : max(0.02, pow(c / theta, 2))
        }
        self.options = options
        self.sampleRate = sampleRate
        self.range = range
    }

    func curve(_ b: EQBand) -> [Double] {
        let c = b.coefficients(sampleRate: sampleRate)
        return freqs.map { c.magnitudeDB(at: $0, sampleRate: sampleRate) }
    }

    /// The cost in dB² of an EQ curve. Lower is better.
    func cost(_ eq: [Double]) -> Double {
        var e = 0.0, w = 0.0, pen = 0.0
        let bt = options.boostTrust.rawValue, ct = options.cutTrust.rawValue
        let restraint = options.boostRestraint.rawValue
        for i in freqs.indices {
            let err = measured[i] + eq[i] - target[i]
            e += weights[i] * err * err
            w += weights[i]
            let g = eq[i]
            if g > 0 {
                // Boost Trust: a boost at a noisy frequency gets no credit, so it costs extra.
                if bt > 0 && coherence[i] < bt { pen += g * g * (1 - coherence[i] / bt) }
                // Boost Restraint: do not fill deep dips. They are usually cancellations that EQ cannot fix.
                let dip = target[i] - measured[i] - 6
                if dip > 0 { pen += restraint * g * dip }
            } else if coherence[i] < ct {
                pen += g * g * (1 - coherence[i] / ct) * 0.5
            }
        }
        return (e + pen) / max(w, 1e-9)
    }

    func clamp(_ b: EQBand) -> EQBand {
        var b = b
        b.frequency = min(max(b.frequency, range.lowerBound), range.upperBound)
        b.gainDB = min(max(b.gainDB, -18), options.maxBoostDB)
        b.q = min(max(b.q, 0.5), 10)
        return b
    }

    func sum(_ curves: [[Double]]) -> [Double] {
        var out = [Double](repeating: 0, count: freqs.count)
        for c in curves { for i in out.indices { out[i] += c[i] } }
        return out
    }

    public func run(progress: (Progress) -> Bool = { _ in true }) -> (filters: [EQBand], errorDB: Double) {
        guard freqs.count > 4 else { return ([], 0) }
        var bands: [EQBand] = []
        var curves: [[Double]] = []
        let flat = [Double](repeating: 0, count: freqs.count)
        let initial = cost(flat)
        var best = initial

        // Step 1: greedy placement with a short coordinate descent per filter.
        for _ in 0..<max(0, options.filterCount) {
            let eq = sum(curves)
            var worst = 0, worstV = 0.0
            for i in freqs.indices {
                // A 1/6-octave neighbourhood stops a single noisy point from attracting a filter.
                let lo = max(0, i - 4), hi = min(freqs.count - 1, i + 4)
                var s = 0.0, w = 0.0
                for k in lo...hi { s += weights[k] * (measured[k] + eq[k] - target[k]); w += weights[k] }
                let v = abs(s / max(w, 1e-9))
                if v > worstV { worstV = v; worst = i }
            }
            if worstV < 0.5 { break }
            let errAt = measured[worst] + eq[worst] - target[worst]
            var b = clamp(EQBand(type: .peaking, frequency: freqs[worst], gainDB: -errAt, q: 2))
            var bc = curve(b)
            var c = cost(sum(curves + [bc]))
            var steps = (f: 0.1, g: 1.0, q: 0.3)
            for _ in 0..<25 {
                var improved = false
                for trial in [
                    { (x: EQBand) -> EQBand in var y = x; y.frequency *= pow(2, steps.f); return y },
                    { (x: EQBand) -> EQBand in var y = x; y.frequency /= pow(2, steps.f); return y },
                    { (x: EQBand) -> EQBand in var y = x; y.gainDB += steps.g; return y },
                    { (x: EQBand) -> EQBand in var y = x; y.gainDB -= steps.g; return y },
                    { (x: EQBand) -> EQBand in var y = x; y.q *= exp(steps.q); return y },
                    { (x: EQBand) -> EQBand in var y = x; y.q /= exp(steps.q); return y },
                ] {
                    let nb = clamp(trial(b))
                    let ncurve = curve(nb)
                    let nc = cost(sum(curves + [ncurve]))
                    if nc < c { b = nb; bc = ncurve; c = nc; improved = true }
                }
                if !improved { steps = (steps.f / 2, steps.g / 2, steps.q / 2) }
                if steps.g < 0.05 { break }
            }
            // Keep the filter only if it helps by a useful margin.
            if c < best * 0.995 {
                bands.append(b); curves.append(bc); best = c
            } else { break }
        }

        // Step 2: evolution strategy over all filters.
        let total = options.generations.rawValue
        var rng = SystemRandomNumberGenerator()
        for gen in 1...total {
            if best <= initial * options.threshold.rawValue * options.threshold.rawValue { break }
            let scale = 1 - Double(gen - 1) / Double(total) * 0.8
            for _ in 0..<24 where !bands.isEmpty {
                var child = bands
                var childCurves = curves
                let k = Int.random(in: 0..<bands.count, using: &rng)
                var b = child[k]
                b.frequency *= pow(2, gauss(&rng) * 0.08 * scale)
                b.gainDB += gauss(&rng) * 0.6 * scale
                b.q *= exp(gauss(&rng) * 0.15 * scale)
                b = clamp(b)
                child[k] = b
                childCurves[k] = curve(b)
                let c = cost(sum(childCurves))
                if c < best { best = c; bands = child; curves = childCurves }
            }
            if !progress(Progress(generation: gen, totalGenerations: total, errorDB: best.squareRoot(), filters: bands)) { break }
        }
        // Drop filters that do almost nothing.
        let kept = bands.filter { abs($0.gainDB) >= 0.3 }
        return (kept.sorted { $0.frequency < $1.frequency }, best.squareRoot())
    }
}

func gauss<R: RandomNumberGenerator>(_ rng: inout R) -> Double {
    let u = Double.random(in: Double.ulpOfOne..<1, using: &rng), v = Double.random(in: 0..<1, using: &rng)
    return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
}
