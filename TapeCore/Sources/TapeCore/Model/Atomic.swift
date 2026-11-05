import TapeAtomics

/// A heap allocated Int64 with acquire/release semantics, safe to touch from the render thread.
public final class AtomicInt64: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Int64>

    public init(_ value: Int64 = 0) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: value)
    }

    deinit { pointer.deallocate() }

    @inline(__always) public func load() -> Int64 { tape_atomic_load(pointer) }
    @inline(__always) public func store(_ value: Int64) { tape_atomic_store(pointer, value) }
    @discardableResult @inline(__always)
    public func add(_ delta: Int64) -> Int64 { tape_atomic_add(pointer, delta) }
}
