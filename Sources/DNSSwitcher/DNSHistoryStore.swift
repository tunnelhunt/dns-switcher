import Foundation
import Combine

/// Dedicated, low-overhead in-memory store for DNS resolution history.
/// Decoupled from `AppViewModel` so that normal DNS query traffic does NOT invalidate `MenuBarView`
/// or trigger background SwiftUI re-layouts when the History/Settings windows are closed.
public final class DNSHistoryStore: ObservableObject, @unchecked Sendable {
    public static let shared = DNSHistoryStore()

    @MainActor @Published public private(set) var records: [DNSResolutionRecord] = []
    @MainActor @Published public private(set) var totalResolvedCount: Int = 0
    public let maxHistoryCount: Int = 500

    private struct State {
        var pendingBatch: [DNSResolutionRecord] = []
        var pendingCount: Int = 0
        var isFlushScheduled = false
        var isUIVisible = false
    }

    private let lock = NSLock()
    private var state = State()

    public var isUIVisible: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return state.isUIVisible
        }
        set {
            lock.lock()
            let changed = (state.isUIVisible != newValue)
            state.isUIVisible = newValue
            lock.unlock()
            if changed && newValue {
                flushPending()
            }
        }
    }

    public init() {}

    /// Logs a resolution record from any thread in a lightweight lock (<1 microsecond).
    /// If UI is not open, it simply appends to an internal array without waking up the main thread.
    public func logRecord(_ record: DNSResolutionRecord) {
        lock.lock()
        if state.pendingBatch.count >= maxHistoryCount {
            state.pendingBatch.removeFirst()
        }
        state.pendingBatch.append(record)
        state.pendingCount += 1
        let shouldSchedule = state.isUIVisible && !state.isFlushScheduled
        if shouldSchedule {
            state.isFlushScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.flushPending()
            }
        }
    }

    /// Flushes buffered records into the `@Published` properties for SwiftUI display.
    public func flushPending() {
        lock.lock()
        guard !state.pendingBatch.isEmpty else {
            state.isFlushScheduled = false
            lock.unlock()
            return
        }
        let batch = state.pendingBatch
        let countInc = state.pendingCount
        state.pendingBatch.removeAll(keepingCapacity: true)
        state.pendingCount = 0
        state.isFlushScheduled = false
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.totalResolvedCount += countInc
            var updated = batch.reversed() + self.records
            if updated.count > self.maxHistoryCount {
                updated = Array(updated.prefix(self.maxHistoryCount))
            }
            self.records = updated
        }
    }

    public func clear() {
        lock.lock()
        state.pendingBatch.removeAll(keepingCapacity: true)
        state.pendingCount = 0
        state.isFlushScheduled = false
        lock.unlock()
        Task { @MainActor [weak self] in
            self?.records.removeAll()
        }
    }
}
