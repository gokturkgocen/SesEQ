import Foundation

/// Single-producer / single-consumer interleaved Float32 ring buffer.
/// Producer = Core Audio IOProc thread; Consumer = AVAudioEngine render thread.
/// Lock-free via atomic head/tail indices (only one writer, only one reader).
final class AudioRingBuffer {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0
    private var readIndex: Int = 0

    init(capacityFrames: Int, channels: Int) {
        self.capacity = capacityFrames * channels
        self.buffer = .allocate(capacity: self.capacity)
        self.buffer.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Producer side. `data` is interleaved.
    func write(_ data: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var remaining = count
        var src = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - writeIndex)
            buffer.advanced(by: writeIndex).update(from: data.advanced(by: src), count: chunk)
            writeIndex = (writeIndex + chunk) % capacity
            src += chunk
            remaining -= chunk
        }
    }

    /// Consumer side. Reads up to `count` interleaved Float samples; returns actual count read.
    func read(_ dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let available = self.available
        let toRead = min(count, available)
        var remaining = toRead
        var dstOff = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - readIndex)
            dst.advanced(by: dstOff).update(from: buffer.advanced(by: readIndex), count: chunk)
            readIndex = (readIndex + chunk) % capacity
            dstOff += chunk
            remaining -= chunk
        }
        return toRead
    }

    private var available: Int {
        let w = writeIndex
        let r = readIndex
        if w >= r { return w - r }
        return capacity - r + w
    }
}
