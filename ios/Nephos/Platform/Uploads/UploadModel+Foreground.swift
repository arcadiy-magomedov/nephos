import Foundation

// Foreground scheduling stays on UploadModel's main actor. State is module-only
// so this lifecycle extension can share it without a second source of truth.
extension UploadModel {
    func foreground() {
        let wasForeground = isForeground
        isForeground = true
        _ = connectivity
        if foregroundTask != nil {
            if !wasForeground {
                needsDiscovery = true
                needsWork = true
            }
            wakeGate.wake()
            return
        }
        needsDiscovery = true
        needsWork = true
        wakeGate.wake()
        let id = UUID()
        foregroundID = id
        foregroundTask = Task { [weak self] in
            await self?.runForeground(id: id)
        }
    }

    private func runForeground(id: UUID) async {
        defer {
            if foregroundID == id {
                foregroundTask = nil
                foregroundID = nil
            }
        }
        await restore()
        var nextWorkAt: Date?
        while !Task.isCancelled, foregroundID == id, isForeground {
            wakeGate.consumePending()
            let now: Date
            do {
                now = try await reload()
            } catch {
                if !AuthSession.isCancelled(error) { report(error) }
                break
            }
            guard !Task.isCancelled, foregroundID == id, isForeground else { break }
            let allowsNetwork = !connectivity.hasPath || connectivity.permits(snapshot.policy)
            let hasPending = snapshot.pendingCount > 0 || !snapshot.pending.isEmpty
            if let deadline = nextWorkAt, now >= deadline {
                nextWorkAt = nil
                requestTimedWork(allowsNetwork: allowsNetwork, hasPending: hasPending)
            }
            let discover = UploadWakePolicy.shouldDiscover(
                for: snapshot, needsDiscovery: needsDiscovery, lastDiscovery: lastDiscovery, now: now)
            if snapshot.policy == .disabled { nextWorkAt = nil }
            if shouldRunWork(discover: discover, allowsNetwork: allowsNetwork, hasPending: hasPending), work == nil {
                nextWorkAt = nil
                _ = startWork(discover: discover)
            }
            let timeout = foregroundTimeout(now: now, allowsNetwork: allowsNetwork, nextWorkAt: &nextWorkAt)
            let outcome = await wakeGate.wait(timeout: timeout)
            if outcome == .cancelled { break }
            if outcome == .timedOut, canRunTimedWork(allowsNetwork: allowsNetwork, hasPending: hasPending) {
                nextWorkAt = nil
                needsWork = true
            }
        }
    }

    private func shouldRunWork(discover: Bool, allowsNetwork: Bool, hasPending: Bool) -> Bool {
        if snapshot.policy == .disabled {
            needsDiscovery = false
            needsWork = false
            return false
        }
        if discover { return true }
        if snapshot.canTransfer, allowsNetwork, needsWork, hasPending { return true }
        if work == nil { needsWork = false }
        return false
    }

    private func canRunTimedWork(allowsNetwork: Bool, hasPending: Bool) -> Bool {
        work == nil && snapshot.canTransfer && allowsNetwork && (hasPending || snapshot.scanning)
    }

    private func requestTimedWork(allowsNetwork: Bool, hasPending: Bool) {
        if canRunTimedWork(allowsNetwork: allowsNetwork, hasPending: hasPending) { needsWork = true }
    }

    private func foregroundTimeout(
        now: Date, allowsNetwork: Bool, nextWorkAt: inout Date?
    ) -> TimeInterval? {
        guard
            let waitSeconds = UploadWakePolicy.nextWait(
                for: snapshot, now: now, allowsNetwork: allowsNetwork, isWorking: work != nil)
        else {
            nextWorkAt = nil
            return nil
        }
        let proposed = now.addingTimeInterval(waitSeconds)
        if let existing = nextWorkAt, existing < proposed {
            return max(0.05, existing.timeIntervalSince(now))
        }
        nextWorkAt = proposed
        return waitSeconds
    }
}
