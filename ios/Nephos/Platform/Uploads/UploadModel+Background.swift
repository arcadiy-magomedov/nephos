import Foundation
import OSLog

extension UploadModel {
    func receivedBackgroundEvent() {
        needsWork = true
        wake()
        guard !isForeground, work == nil else { return }
        backgroundWindow(completions: [])
    }

    func finishedBackgroundEvents() {
        needsWork = true
        wake()
        let completions = backgroundCompletions
        backgroundCompletions.removeAll()
        backgroundWindow(completions: completions)
    }

    private func backgroundWindow(completions: [() -> Void]) {
        let logger = self.logger
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await self.backgroundCheck(discover: false) }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(20)) } catch is CancellationError { return } catch {
                        logger.error(
                            "Background upload deadline failed: \(error.localizedDescription, privacy: .private)")
                    }
                }
                _ = await group.next()
                group.cancelAll()
                // Outcomes were persisted by the URLSession delegate before entering this window.
                for completion in completions { completion() }
            }
        }
    }

    func networkChanged() {
        if !connectivity.permits(snapshot.policy) {
            work?.cancel()
            if snapshot.policy == .wiFiOnly {
                Task { await transport?.cancel(scope: destination?.scope) }
            }
        } else if snapshot.canTransfer {
            needsWork = true
        }
        wake()
    }
}
