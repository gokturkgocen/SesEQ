import Accelerate
import Foundation

/// Computes the exact mel-spectrogram that Discogs-EffNet was trained on, matching
/// Essentia's TensorflowInputMusiCNN bit-for-bit (verified in Python against essentia,
/// max diff 0.0). Recipe:
///   512-sample frame, hop 256, symmetric RAW Hann window
///   -> |rfft|^2 (POWER spectrum, 257 bins)
///   -> 96x257 unit_tri slaneyMel filterbank (loaded from resource)
///   -> log10(10000 * mel + 1)
///
/// Input audio MUST be 16 kHz mono.
final class MelSpectrogram {
    static let frameSize = 512
    static let hop = 256
    static let nBands = 96
    static let nSpec = 257          // frameSize/2 + 1
    static let patchFrames = 128    // model input is [128, 96]

    private let log2n: vDSP_Length = 9   // 2^9 = 512
    private let fftSetup: FFTSetup
    private let window: [Float]          // symmetric raw Hann, 512
    private let filterbank: [Float]      // 96 * 257, row-major

    init?(filterbankURL: URL) {
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup

        // Symmetric raw Hann (== numpy np.hanning(512)): w[n] = 0.5 - 0.5*cos(2πn/(N-1))
        let N = MelSpectrogram.frameSize
        var w = [Float](repeating: 0, count: N)
        for n in 0..<N {
            w[n] = 0.5 - 0.5 * cos(2.0 * Float.pi * Float(n) / Float(N - 1))
        }
        window = w

        guard let data = try? Data(contentsOf: filterbankURL),
              data.count == MelSpectrogram.nBands * MelSpectrogram.nSpec * MemoryLayout<Float>.size
        else { return nil }
        filterbank = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Compute 96 log-mel bands for one 512-sample frame.
    func melFrame(_ frame: UnsafePointer<Float>) -> [Float] {
        let n = MelSpectrogram.frameSize

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: MelSpectrogram.nSpec)

        windowed.withUnsafeBufferPointer { wbuf in
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wbuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cbuf in
                        vDSP_ctoz(cbuf, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // vDSP real-FFT packing: realp[0]=DC, imagp[0]=Nyquist, k=1..255 = bins.
                    // vDSP forward is scaled by 2 vs standard DFT, so |X|^2 = (re^2+im^2)*0.25.
                    let r = rp.baseAddress!, i = ip.baseAddress!
                    power[0] = r[0] * r[0] * 0.25
                    power[MelSpectrogram.nSpec - 1] = i[0] * i[0] * 0.25
                    for k in 1..<(n / 2) {
                        power[k] = (r[k] * r[k] + i[k] * i[k]) * 0.25
                    }
                }
            }
        }

        // mel = filterbank (96x257) * power (257)
        var mel = [Float](repeating: 0, count: MelSpectrogram.nBands)
        filterbank.withUnsafeBufferPointer { fb in
            power.withUnsafeBufferPointer { pw in
                vDSP_mmul(fb.baseAddress!, 1, pw.baseAddress!, 1, &mel, 1,
                          vDSP_Length(MelSpectrogram.nBands), 1, vDSP_Length(MelSpectrogram.nSpec))
            }
        }

        // log10(10000 * mel + 1)
        var scaled = [Float](repeating: 0, count: MelSpectrogram.nBands)
        var mul: Float = 10000, add: Float = 1
        vDSP_vsmsa(mel, 1, &mul, &add, &scaled, 1, vDSP_Length(MelSpectrogram.nBands))
        var out = [Float](repeating: 0, count: MelSpectrogram.nBands)
        var cnt = Int32(MelSpectrogram.nBands)
        vvlog10f(&out, scaled, &cnt)
        return out
    }

    /// Build a [128 x 96] patch (row-major, 128*96 floats) starting at `startSample`.
    /// Returns nil if not enough samples.
    func patch(from samples: [Float], startSample: Int) -> [Float]? {
        let need = (MelSpectrogram.patchFrames - 1) * MelSpectrogram.hop + MelSpectrogram.frameSize
        guard startSample + need <= samples.count else { return nil }
        var out = [Float](repeating: 0, count: MelSpectrogram.patchFrames * MelSpectrogram.nBands)
        samples.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for f in 0..<MelSpectrogram.patchFrames {
                let s = startSample + f * MelSpectrogram.hop
                let mel = melFrame(base + s)
                for b in 0..<MelSpectrogram.nBands {
                    out[f * MelSpectrogram.nBands + b] = mel[b]
                }
            }
        }
        return out
    }

    /// Diagnostic: max abs diff between our patch output and a reference patch.
    /// Used by the launch self-test to catch FFT scaling/packing regressions.
    func selfTestMaxDiff(inputURL: URL, expectedMelURL: URL) -> Float? {
        guard let inData = try? Data(contentsOf: inputURL),
              let melData = try? Data(contentsOf: expectedMelURL) else { return nil }
        let samples = inData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let expected = melData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard let got = patch(from: samples, startSample: 0),
              got.count == expected.count else { return nil }
        var maxDiff: Float = 0
        for i in 0..<got.count { maxDiff = max(maxDiff, abs(got[i] - expected[i])) }
        return maxDiff
    }
}
