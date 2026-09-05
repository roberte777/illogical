//  AtomicFlag.swift
//  A thread-safe boolean.
//
//  The dirty flag is read by the display link on every tick and written by
//  the connection's reader thread on every write, so it can't live behind the
//  terminal lock: an idle terminal would then pay a lock acquisition 120
//  times a second just to be told there is nothing to do.
//
//  `os_unfair_lock` rather than a real atomic because Swift's
//  `Synchronization.Atomic` needs macOS 15 and we target 14. Uncontended
//  acquire and release is a handful of nanoseconds, which is well inside the
//  budget for something read at display rate.

import Foundation

final class Atomic: @unchecked Sendable {
    private var value: Bool
    private var lock = os_unfair_lock()

    init(_ value: Bool) { self.value = value }

    func load() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }

    func store(_ newValue: Bool) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }

    /// Set and return the previous value. Lets a caller act only on the
    /// clean-to-dirty edge rather than on every write.
    func exchange(_ newValue: Bool) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let old = value
        value = newValue
        return old
    }
}
