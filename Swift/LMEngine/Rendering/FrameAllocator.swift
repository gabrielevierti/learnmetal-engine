// FrameAllocator.swift
// Memory for everything that changes every frame: uniforms, instance data, 2D vertices.
//
// It is one large Metal buffer per frame in flight, filled from the start each frame
// (a "bump allocator"): allocating is adding to an offset, and freeing is setting the
// offset back to zero. The renderer keeps three of these and cycles through them,
// because the GPU may still be reading the buffers of the previous two frames.

import Metal

final class FrameAllocator {
    struct Allocation {
        var buffer: MTLBuffer
        var offset: Int
        var pointer: UnsafeMutableRawPointer
    }

    private let device: MTLDevice
    private var buffer: MTLBuffer
    private var retired: [MTLBuffer] = []
    private var capacity: Int
    private var offset = 0

    init(device: MTLDevice, capacity: Int) {
        self.device = device
        self.capacity = capacity
        buffer = FrameAllocator.makeBuffer(device, capacity)
    }

    private static func makeBuffer(_ device: MTLDevice, _ capacity: Int) -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else {
            fatalError("cannot allocate \(capacity) bytes for per-frame data")
        }
        return buffer
    }

    /// Starts a new frame. Whatever was allocated before may be overwritten.
    func reset() {
        offset = 0
        retired.removeAll()         // the frames that used the old buffers have finished by now
    }

    /// `alignment` 256 satisfies every GPU's rule for the offset of a bound buffer.
    func allocate(size: Int, alignment: Int = 256) -> Allocation {
        var start = (offset + alignment - 1) / alignment * alignment
        if start + size > capacity {
            // Out of room: switch to a larger buffer. Earlier allocations of this frame
            // stay valid, because the old buffer is kept alive until the next reset.
            retired.append(buffer)
            capacity = (capacity + size) * 2
            buffer = FrameAllocator.makeBuffer(device, capacity)
            start = 0
        }
        offset = start + size
        return Allocation(buffer: buffer, offset: start, pointer: buffer.contents() + start)
    }

    func copy<T>(_ value: T) -> Allocation {
        let allocation = allocate(size: MemoryLayout<T>.stride)
        withUnsafeBytes(of: value) { bytes in
            allocation.pointer.copyMemory(from: bytes.baseAddress!, byteCount: MemoryLayout<T>.size)
        }
        return allocation
    }

    func copyArray<T>(_ values: [T]) -> Allocation {
        let allocation = allocate(size: MemoryLayout<T>.stride * max(values.count, 1))
        values.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress, bytes.count > 0 {
                allocation.pointer.copyMemory(from: source, byteCount: bytes.count)
            }
        }
        return allocation
    }
}
