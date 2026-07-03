import Foundation

/// Computes the combined magnitude response (dB vs frequency) of an EQ preset's
/// biquad bands, for drawing the EQ curve in the UI. Uses RBJ cookbook biquads.
/// This is a faithful *visual* representation of what AVAudioUnitEQ applies.
enum FrequencyResponse {
    static let minHz: Double = 20
    static let maxHz: Double = 20000

    /// Log-spaced frequency axis with `points` samples from 20 Hz to 20 kHz.
    static func frequencyAxis(points: Int) -> [Double] {
        let logMin = log10(minHz), logMax = log10(maxHz)
        return (0..<points).map { i in
            pow(10, logMin + (logMax - logMin) * Double(i) / Double(points - 1))
        }
    }

    /// Returns the response in dB at each frequency in `freqs`.
    static func responseDB(bands: [EQBand], globalGainDB: Float, sampleRate: Double, freqs: [Double]) -> [Double] {
        var out = [Double](repeating: Double(globalGainDB), count: freqs.count)
        for band in bands where abs(band.gain) > 0.001 {
            let coeffs = biquad(for: band, sampleRate: sampleRate)
            for (i, f) in freqs.enumerated() {
                out[i] += coeffs.magnitudeDB(at: f, sampleRate: sampleRate)
            }
        }
        return out
    }

    // MARK: - Biquad

    private struct Biquad {
        let b0, b1, b2, a0, a1, a2: Double

        func magnitudeDB(at f: Double, sampleRate: Double) -> Double {
            let w = 2 * Double.pi * f / sampleRate
            let cosw = cos(w), cos2w = cos(2 * w)
            let sinw = sin(w), sin2w = sin(2 * w)
            // numerator b0 + b1 e^-jw + b2 e^-2jw
            let nRe = b0 + b1 * cosw + b2 * cos2w
            let nIm = -(b1 * sinw + b2 * sin2w)
            let dRe = a0 + a1 * cosw + a2 * cos2w
            let dIm = -(a1 * sinw + a2 * sin2w)
            let num = sqrt(nRe * nRe + nIm * nIm)
            let den = sqrt(dRe * dRe + dIm * dIm)
            guard den > 0 else { return 0 }
            return 20 * log10(num / den)
        }
    }

    /// bandwidth(octaves) -> Q for peaking filters.
    private static func qFromBandwidth(_ bwOctaves: Float) -> Double {
        let n = Double(max(bwOctaves, 0.05))
        let twoN = pow(2.0, n)
        return sqrt(twoN) / (twoN - 1)
    }

    private static func biquad(for band: EQBand, sampleRate: Double) -> Biquad {
        let f0 = Double(band.frequency)
        let gain = Double(band.gain)
        let Q = qFromBandwidth(band.bandwidth)
        let A = pow(10, gain / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw0 = cos(w0), sinw0 = sin(w0)
        let alpha = sinw0 / (2 * Q)

        switch band.filterType {
        case .parametric:
            let b0 = 1 + alpha * A
            let b1 = -2 * cosw0
            let b2 = 1 - alpha * A
            let a0 = 1 + alpha / A
            let a1 = -2 * cosw0
            let a2 = 1 - alpha / A
            return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
        case .lowShelf:
            let sq = 2 * sqrt(A) * alpha
            let b0 = A * ((A + 1) - (A - 1) * cosw0 + sq)
            let b1 = 2 * A * ((A - 1) - (A + 1) * cosw0)
            let b2 = A * ((A + 1) - (A - 1) * cosw0 - sq)
            let a0 = (A + 1) + (A - 1) * cosw0 + sq
            let a1 = -2 * ((A - 1) + (A + 1) * cosw0)
            let a2 = (A + 1) + (A - 1) * cosw0 - sq
            return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
        case .highShelf:
            let sq = 2 * sqrt(A) * alpha
            let b0 = A * ((A + 1) + (A - 1) * cosw0 + sq)
            let b1 = -2 * A * ((A - 1) + (A + 1) * cosw0)
            let b2 = A * ((A + 1) + (A - 1) * cosw0 - sq)
            let a0 = (A + 1) - (A - 1) * cosw0 + sq
            let a1 = 2 * ((A - 1) - (A + 1) * cosw0)
            let a2 = (A + 1) - (A - 1) * cosw0 - sq
            return Biquad(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
        case .lowPass, .highPass:
            // Not used by current presets; return flat.
            return Biquad(b0: 1, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)
        }
    }
}
