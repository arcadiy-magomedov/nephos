import Foundation

enum UploadWakePolicy: Sendable {
    static let activeInterval: TimeInterval = 1
    static let verifyingInterval: TimeInterval = 2
    static let scheduledInterval: TimeInterval = 2
    static let minRetryInterval: TimeInterval = 2
    static let maxRetryInterval: TimeInterval = 15
    static let completionBannerDuration: TimeInterval = 2
    static let discoveryInterval: TimeInterval = 15

    static func showsProgress(for batch: UploadBatch?, now: Date = Date()) -> Bool {
        guard let batch else { return false }
        guard let completedAt = batch.completedAt else { return true }
        return now.timeIntervalSince(completedAt) < completionBannerDuration
    }

    static func completionBannerRemaining(for batch: UploadBatch?, now: Date = Date()) -> TimeInterval? {
        guard let completedAt = batch?.completedAt else { return nil }
        let remaining = completionBannerDuration - now.timeIntervalSince(completedAt)
        guard remaining > 0 else { return nil }
        return min(completionBannerDuration, remaining)
    }

    static func shouldDiscover(
        for snapshot: UploadSnapshot,
        needsDiscovery: Bool,
        lastDiscovery: Date?,
        now: Date = Date()
    ) -> Bool {
        guard snapshot.policy != .disabled else { return false }
        if needsDiscovery || snapshot.scanning { return true }
        guard snapshot.canTransfer, snapshot.pendingCount > 0 || !snapshot.pending.isEmpty else {
            return false
        }
        guard let lastDiscovery else { return true }
        return now.timeIntervalSince(lastDiscovery) >= discoveryInterval
    }

    static func nextWait(
        for snapshot: UploadSnapshot,
        now: Date = Date(),
        allowsNetwork: Bool = true,
        isWorking: Bool = false,
        coordinatorRetryAt: Date? = nil
    ) -> TimeInterval? {
        let bannerRemaining = completionBannerRemaining(for: snapshot.batch, now: now)
        guard snapshot.canTransfer, allowsNetwork else {
            return bannerRemaining
        }
        if snapshot.scanning || isWorking {
            return minOptional(activeInterval, bannerRemaining)
        }
        let hasPending = snapshot.pendingCount > 0 || !snapshot.pending.isEmpty
        guard hasPending else {
            return bannerRemaining
        }
        let coordinatorBackoff = coordinatorRetryAt.flatMap { deadline -> TimeInterval? in
            let delta = deadline.timeIntervalSince(now)
            return delta > 0 ? clampRetry(delta) : nil
        }
        var earliest: TimeInterval?
        for item in snapshot.pending where !item.phase.isTerminal {
            let itemWait = wait(for: item, now: now, coordinatorBackoff: coordinatorBackoff)
            earliest = minOptional(earliest, itemWait)
        }
        if earliest == nil {
            earliest = coordinatorBackoff ?? scheduledInterval
        }
        return minOptional(earliest, bannerRemaining)
    }

    private static func wait(
        for item: UploadItem, now: Date, coordinatorBackoff: TimeInterval?
    ) -> TimeInterval {
        switch item.phase {
        case .uploading:
            return activeInterval
        case .preparing:
            return coordinatorBackoff ?? activeInterval
        case .verifying:
            return coordinatorBackoff ?? verifyingInterval
        case .scheduled, .queued:
            if let coordinatorBackoff { return coordinatorBackoff }
            return scheduledWait(for: item, now: now)
        case .succeeded, .failed:
            return scheduledInterval
        }
    }

    private static func scheduledWait(for item: UploadItem, now: Date) -> TimeInterval {
        let activeResources = item.resources.filter { $0.phase != .ready && $0.phase != .failed }
        guard !activeResources.isEmpty else { return scheduledInterval }
        var earliestFutureRetry: Date?
        for resource in activeResources {
            guard let retryAfter = resource.retryAfter, retryAfter > now else {
                return scheduledInterval
            }
            if let current = earliestFutureRetry {
                if retryAfter < current { earliestFutureRetry = retryAfter }
            } else {
                earliestFutureRetry = retryAfter
            }
        }
        guard let earliestFutureRetry else { return scheduledInterval }
        return clampRetry(earliestFutureRetry.timeIntervalSince(now))
    }

    private static func clampRetry(_ interval: TimeInterval) -> TimeInterval {
        min(maxRetryInterval, max(minRetryInterval, interval))
    }

    private static func minOptional(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case (let left?, let right?): min(left, right)
        case (let left?, nil): left
        case (nil, let right?): right
        case (nil, nil): nil
        }
    }
}

@MainActor
final class UploadWakeGate {
    enum Outcome: Equatable, Sendable {
        case woken
        case timedOut
        case cancelled
    }

    private let minimumSleep: TimeInterval
    private var pendingWake = false
    private var waiterID: UInt64 = 0
    private var waiter: (id: UInt64, continuation: CheckedContinuation<Outcome, Never>)?
    private var timerTask: Task<Void, Never>?

    init(minimumSleep: TimeInterval = 0.05) {
        self.minimumSleep = minimumSleep
    }

    func wake() {
        if let active = waiter {
            waiter = nil
            timerTask?.cancel()
            timerTask = nil
            pendingWake = false
            active.continuation.resume(returning: .woken)
        } else {
            pendingWake = true
        }
    }

    func consumePending() {
        pendingWake = false
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        pendingWake = false
        if let active = waiter {
            waiter = nil
            active.continuation.resume(returning: .cancelled)
        }
    }

    func wait(timeout: TimeInterval?) async -> Outcome {
        if pendingWake {
            pendingWake = false
            return .woken
        }
        if Task.isCancelled {
            return .cancelled
        }
        waiterID &+= 1
        let id = waiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pendingWake {
                    pendingWake = false
                    continuation.resume(returning: .woken)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if let previous = waiter {
                    waiter = nil
                    timerTask?.cancel()
                    timerTask = nil
                    previous.continuation.resume(returning: .cancelled)
                }
                waiter = (id: id, continuation: continuation)
                if let timeout {
                    let seconds = max(minimumSleep, timeout)
                    timerTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(seconds))
                        } catch {
                            return
                        }
                        self?.finish(id: id, outcome: .timedOut)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, outcome: .cancelled)
            }
        }
    }

    private func finish(id: UInt64, outcome: Outcome) {
        guard let active = waiter, active.id == id else { return }
        waiter = nil
        timerTask?.cancel()
        timerTask = nil
        active.continuation.resume(returning: outcome)
    }
}
