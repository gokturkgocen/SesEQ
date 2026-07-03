import Foundation

/// Overwriting circular buffer of mono Float samples for genre analysis.
/// Unlike AudioRingBuffer (consume-on-read SPSC for the EQ path), this keeps a
/// rolling window of the most-recent N samples that can be *peeked* at any time
/// without consuming. The producer (Core Audio IO thread) overwrites the oldest
/// samples; a consumer snapshots the latest window.
///
/// Lock-free with a benign boundary race: a snapshot taken concurrently with a
/// write may include a handful of just-overwritten samples. Irrelevant for genre
/// classification, which looks at seconds of audio.
final class AnalysisRingBuffer {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0
    private var filled: Int = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        self.buffer = .allocate(capacity: self.capacity)
        self.buffer.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Producer side (RT thread). Appends mono samples, overwriting oldest.
    func write(_ p: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var src = 0
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            buffer.advanced(by: writeIndex).update(from: p.advanced(by: src), count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            src += chunk
            remaining -= chunk
        }
        filled = min(filled + count, capacity)
    }

    /// Consumer side. Returns the most recent `n` samples in chronological order,
    /// or fewer if not enough have accumulated. nil if empty.
    func snapshotLast(_ n: Int) -> [Float]? {
        let available = min(n, filled)
        guard available > 0 else { return nil }
        var out = [Float](repeating: 0, count: available)
        // The most recent sample is at (writeIndex - 1). Start = writeIndex - available.
        let start = ((writeIndex - available) % capacity + capacity) % capacity
        out.withUnsafeMutableBufferPointer { dst in
            var idx = start
            for i in 0..<available {
                dst[i] = buffer[idx]
                idx += 1
                if idx == capacity { idx = 0 }
            }
        }
        return out
    }
}
