import Foundation

/// The phase correction pass ("Fine-tuning phase alignment" in the Omnissiah manual).
///
/// Delay and polarity align the subwoofer and the tops at one frequency only. A crossover or a
/// speaker can also rotate the phase, and a delay cannot fix a rotation. This pass adds up to three
/// second-order all-pass filters to one side of the crossover. The filters change the phase only,
/// so the magnitude and the headroom stay the same.
///
/// An all-pass filter can only add phase lag. The filters therefore go on the side whose phase
/// leads. `align` tries both sides and keeps the better result, so the caller does not need to know
/// which side leads.
///
/// The cost is the same as the cost of the fine alignment in `CalibrationPlanner`.
/// It is Σ min(|A|, |B|) · (1 − cos Δφ) over each pair of channels, divided by Σ min(|A|, |B|).
/// A value of 0 means that the channels are in phase. A value of 2 means that they cancel.
public enum PhaseAligner {
    /// The pass keeps the filters only if they lower the cost by at least this fraction.
    public static let minimumImprovement = 0.05
    /// The pass also needs this absolute drop of the cost. A cost of 0.01 is a mean phase error of about 8°.
    public static let minimumDrop = 0.01

    /// The weighted phase error of `channels` against `others` in `band`, with `filters` added to `channels`.
    ///
    /// Each response must carry its latency. The function adds the latency to the phase,
    /// so a delay that `Response.applying` added is part of the comparison.
    public static func cost(_ channels: [Response], against others: [Response], band: ClosedRange<Double>, filters: [EQBand] = []) -> Double {
        guard let p = Pairs(channels, others, band: band) else { return 0 }
        return p.cost(p.phase(filters))
    }

    /// Finds up to `maxFilters` all-pass filters for `channels` that bring them in phase with `others` in `band`.
    ///
    /// All of `channels` get the same filters, so their phase relation to each other stays the same.
    /// The function returns no filters if they lower the cost by less than `minimumImprovement` or `minimumDrop`.
    /// It also returns no filters if they lower the mean level of the complex sum.
    /// This level guard covers one octave below `band` to one octave above it.
    public static func allPassFilters(for channels: [Response], against others: [Response], band: ClosedRange<Double>,
                                      maxFilters: Int = 3) -> (filters: [EQBand], before: Double, after: Double) {
        guard let p = Pairs(channels, others, band: band) else { return ([], 0, 0) }
        let before = p.cost(p.phase([]))
        guard before >= minimumDrop else { return ([], before, before) }
        let sr = channels[0].sampleRate
        let fLow = max(20, band.lowerBound / 2), fHigh = min(band.upperBound * 2, 0.45 * sr)
        guard fLow < fHigh else { return ([], before, before) }
        let fLimits = fLow...fHigh
        // A high Q adds a long group delay at low frequencies: 2 Q / (π f), or 95 ms at 20 Hz for Q 3.
        let qLimits = 0.2...3.0
        func clamp(_ b: EQBand) -> EQBand {
            var b = b
            b.frequency = min(max(b.frequency, fLimits.lowerBound), fLimits.upperBound)
            b.q = min(max(b.q, qLimits.lowerBound), qLimits.upperBound)
            return b
        }
        // A coordinate descent over the frequency and the Q of one filter, with the other filters fixed.
        func refine(_ bands: inout [EQBand], _ k: Int, _ cost: inout Double) {
            var stepF = 0.1, stepQ = 0.2
            while stepF > 0.002 {
                var improved = false
                for (df, dq) in [(stepF, 0.0), (-stepF, 0.0), (0.0, stepQ), (0.0, -stepQ)] {
                    var trial = bands
                    trial[k].frequency *= pow(2, df)
                    trial[k].q *= exp(dq)
                    trial[k] = clamp(trial[k])
                    let c = p.cost(p.phase(trial))
                    if c < cost { bands = trial; cost = c; improved = true }
                }
                if !improved { stepF /= 2; stepQ /= 2 }
            }
        }

        var bands: [EQBand] = []
        var best = before
        let qs = [0.3, 0.5, 0.7, 1.0, 1.4, 2.0, 3.0]
        for _ in 0..<max(0, maxFilters) {
            // A grid search at 1/12 octave for the start point of the new filter.
            var candidate = bands, candidateCost = Double.infinity
            var f = fLimits.lowerBound
            while f <= fLimits.upperBound {
                for q in qs {
                    let trial = bands + [EQBand(type: .allPass, frequency: f, gainDB: 0, q: q)]
                    let c = p.cost(p.phase(trial))
                    if c < candidateCost { candidate = trial; candidateCost = c }
                }
                f *= pow(2, 1.0 / 12)
            }
            refine(&candidate, candidate.count - 1, &candidateCost)
            // Two rounds over all filters, because a new filter changes the best place of the old ones.
            for _ in 0..<2 { for k in candidate.indices { refine(&candidate, k, &candidateCost) } }
            // A new filter must lower the cost by 2 % and by half of `minimumDrop`, or the pass stops.
            guard candidateCost < best * 0.98, best - candidateCost >= minimumDrop / 2 else { break }
            bands = candidate
            best = candidateCost
        }
        // The level guard: the pass must not lower the mean level of the complex sum near the crossover.
        guard !bands.isEmpty, best <= before * (1 - minimumImprovement), before - best >= minimumDrop,
              p.sumLoss(bands) <= p.sumLoss([]) + 1e-9 else { return ([], before, before) }
        return (bands.sorted { $0.frequency < $1.frequency }, before, best)
    }

    /// Runs the pass on the side that gives the lower cost: the subwoofers or the tops.
    ///
    /// The returned filters go on every channel of the chosen side. `onSubwoofers` is false when
    /// the tops get the filters. The result has no filters when neither side improves the cost.
    public static func align(subwoofers: [Response], tops: [Response], band: ClosedRange<Double>,
                             maxFilters: Int = 3) -> (onSubwoofers: Bool, filters: [EQBand], before: Double, after: Double) {
        let onSubs = allPassFilters(for: subwoofers, against: tops, band: band, maxFilters: maxFilters)
        let onTops = allPassFilters(for: tops, against: subwoofers, band: band, maxFilters: maxFilters)
        if onTops.filters.isEmpty && onSubs.filters.isEmpty { return (true, [], onSubs.before, onSubs.before) }
        if onSubs.filters.isEmpty || (!onTops.filters.isEmpty && onTops.after < onSubs.after) {
            return (false, onTops.filters, onTops.before, onTops.after)
        }
        return (true, onSubs.filters, onSubs.before, onSubs.after)
    }

    /// The precomputed sums of the cost for the grid points in the band.
    ///
    /// The first side gets the filter phase ψ. Then Σ w · cos(Δφ + ψ) = A · cos ψ − B · sin ψ.
    /// Here, A = Σ w · cos Δφ and B = Σ w · sin Δφ. One cost evaluation is then one pass over the band.
    struct Pairs {
        let freqs: [Double]
        let sampleRate: Double
        let a: [Double], b: [Double], totalWeight: Double
        /// The grid points and complex values of the level guard: the band and one octave on each side.
        let guardFreqs: [Double]
        let guardFirst: [[Complex]], guardSecond: [[Complex]]

        init?(_ first: [Response], _ second: [Response], band: ClosedRange<Double>) {
            guard let sr = first.first?.sampleRate, !second.isEmpty else { return nil }
            let grid = FrequencyGrid.frequencies
            func value(_ r: Response, _ i: Int) -> Complex {
                r.complex(i) * Complex.polar(1, -2 * .pi * grid[i] * Double(r.latencySamples) / r.sampleRate)
            }
            let idx = grid.indices.filter { band.contains(grid[$0]) }
            guard !idx.isEmpty else { return nil }
            var a = [Double](repeating: 0, count: idx.count), b = a, total = 0.0
            for (n, i) in idx.enumerated() {
                for x in first {
                    for y in second {
                        let hx = value(x, i), hy = value(y, i)
                        let w = min(hx.magnitude, hy.magnitude)
                        let d = hx.phase - hy.phase
                        a[n] += w * cos(d); b[n] += w * sin(d); total += w
                    }
                }
            }
            guard total > 0 else { return nil }
            freqs = idx.map { grid[$0] }
            sampleRate = sr
            self.a = a; self.b = b; totalWeight = total
            let g = grid.indices.filter { grid[$0] >= band.lowerBound / 2 && grid[$0] <= band.upperBound * 2 }
            guardFreqs = g.map { grid[$0] }
            guardFirst = first.map { r in g.map { value(r, $0) } }
            guardSecond = second.map { r in g.map { value(r, $0) } }
        }

        /// The total phase of `filters` at each band frequency, in radians.
        func phase(_ filters: [EQBand]) -> [Double] {
            var psi = [Double](repeating: 0, count: freqs.count)
            for f in filters {
                let c = f.coefficients(sampleRate: sampleRate)
                for n in freqs.indices { psi[n] += c.response(at: freqs[n], sampleRate: sampleRate).phase }
            }
            return psi
        }

        func cost(_ psi: [Double]) -> Double {
            var s = 0.0
            for n in freqs.indices { s += a[n] * cos(psi[n]) - b[n] * sin(psi[n]) }
            return (totalWeight - s) / totalWeight
        }

        /// The mean loss in dB of the complex sum against the magnitude sum, with `filters` on the first side.
        func sumLoss(_ filters: [EQBand]) -> Double {
            let coeffs = filters.map { $0.coefficients(sampleRate: sampleRate) }
            var loss = 0.0
            for (n, f) in guardFreqs.enumerated() {
                var ap = Complex.one
                for c in coeffs { ap = ap * c.response(at: f, sampleRate: sampleRate) }
                var sum = Complex.zero, mags = 0.0
                for h in guardFirst { sum += h[n] * ap; mags += h[n].magnitude }
                for h in guardSecond { sum += h[n]; mags += h[n].magnitude }
                loss += 20 * log10(max(mags, 1e-12) / max(sum.magnitude, 1e-12))
            }
            return loss / Double(max(guardFreqs.count, 1))
        }
    }
}
