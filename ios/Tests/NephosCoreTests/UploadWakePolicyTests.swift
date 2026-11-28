import Foundation
import Testing

@testable import NephosCore

@Suite
struct UploadWakePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeResource(
        id: String = "res-1",
        phase: UploadResourcePhase = .scheduled,
        retryAfter: Date? = nil
    ) -> UploadResource {
        UploadResource(
            id: UploadIdentity.id([id]),
            descriptor: UploadResourceDescriptor(
                type: 1, role: "photo", filename: "\(id).HEIC",
                uniformTypeIdentifier: "public.heic", mediaType: "image/heic", isPrimary: true),
            phase: phase,
            retryAfter: retryAfter)
    }

    private func makeItem(
        id: String = "item-1",
        phase: UploadPhase,
        resources: [UploadResource]? = nil
    ) -> UploadItem {
        let itemID = UploadIdentity.id([id])
        let resourceList = resources ?? [makeResource(id: "\(id)-primary")]
        return UploadItem(
            id: itemID,
            batchID: UploadIdentity.id(["batch"]),
            scope: "fixture-scope",
            resourceSetID: itemID,
            localIdentifier: id,
            sourceRevision: "rev-1",
            kind: "single",
            capturedAt: nil,
            resources: resourceList,
            phase: phase,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now)
    }

    private func makeSnapshot(
        policy: UploadPolicy = .allNetworks,
        paused: Bool = false,
        scanning: Bool = false,
        batch: UploadBatch? = nil,
        pending: [UploadItem] = [],
        pendingCount: Int? = nil,
        failedCount: Int = 0
    ) -> UploadSnapshot {
        UploadSnapshot(
            policy: policy,
            paused: paused,
            scanning: scanning,
            notice: nil,
            batch: batch,
            succeeded: [],
            failed: [],
            pending: pending,
            succeededCount: batch?.succeeded ?? 0,
            failedCount: failedCount,
            pendingCount: pendingCount ?? pending.count)
    }

    private func makeBatch(
        total: Int = 5,
        succeeded: Int = 5,
        failed: Int = 0,
        completedAt: Date? = nil
    ) -> UploadBatch {
        UploadBatch(
            id: UploadIdentity.id(["batch"]),
            total: total,
            succeeded: succeeded,
            failed: failed,
            createdAt: now.addingTimeInterval(-120),
            completedAt: completedAt)
    }

    @Test("Disabled policy parks completely idle")
    func disabledParksIdle() {
        let empty = makeSnapshot(policy: .disabled)
        let withPending = makeSnapshot(
            policy: .disabled,
            batch: makeBatch(total: 3, succeeded: 1, completedAt: nil),
            pending: [makeItem(phase: .uploading)])
        let expired = makeSnapshot(
            policy: .disabled,
            batch: makeBatch(completedAt: now.addingTimeInterval(-5)))

        #expect(UploadWakePolicy.nextWait(for: empty, now: now) == nil)
        #expect(UploadWakePolicy.nextWait(for: withPending, now: now) == nil)
        #expect(UploadWakePolicy.nextWait(for: expired, now: now) == nil)
    }

    @Test("Paused queue parks completely idle")
    func pausedParksIdle() {
        let pausedWithWork = makeSnapshot(
            policy: .allNetworks,
            paused: true,
            batch: makeBatch(total: 4, succeeded: 1, completedAt: nil),
            pending: [makeItem(phase: .uploading), makeItem(id: "item-2", phase: .verifying)])
        let pausedDrained = makeSnapshot(
            policy: .wiFiOnly,
            paused: true,
            batch: makeBatch(completedAt: now.addingTimeInterval(-10)))

        #expect(UploadWakePolicy.nextWait(for: pausedWithWork, now: now) == nil)
        #expect(UploadWakePolicy.nextWait(for: pausedDrained, now: now) == nil)
    }

    @Test("Drained queue after 2-second banner expiry parks completely idle")
    func drainedAfterBannerExpiryParksIdle() {
        let exactBoundary = makeSnapshot(
            batch: makeBatch(completedAt: now.addingTimeInterval(-UploadWakePolicy.completionBannerDuration)))
        let longExpired = makeSnapshot(
            batch: makeBatch(completedAt: now.addingTimeInterval(-30)))
        let noBatch = makeSnapshot(batch: nil)
        let failedOnly = makeSnapshot(
            batch: makeBatch(total: 2, succeeded: 1, failed: 1, completedAt: nil),
            pending: [],
            failedCount: 1)

        #expect(UploadWakePolicy.nextWait(for: exactBoundary, now: now) == nil)
        #expect(UploadWakePolicy.nextWait(for: longExpired, now: now) == nil)
        #expect(UploadWakePolicy.nextWait(for: noBatch, now: now) == nil)
        #expect(UploadWakePolicy.nextWait(for: failedOnly, now: now) == nil)
        #expect(!UploadWakePolicy.showsProgress(for: exactBoundary.batch, now: now))
        #expect(!UploadWakePolicy.showsProgress(for: longExpired.batch, now: now))
    }

    @Test("Recently completed batch wakes at remaining completion banner expiry")
    func recentlyCompletedBatchWakesAtRemainingBannerExpiry() {
        let halfSecondAgo = makeBatch(completedAt: now.addingTimeInterval(-0.5))
        let almostExpired = makeBatch(completedAt: now.addingTimeInterval(-1.75))
        let futureClockSkew = makeBatch(completedAt: now.addingTimeInterval(5))

        let waitHalf = UploadWakePolicy.nextWait(for: makeSnapshot(batch: halfSecondAgo), now: now)
        let waitAlmost = UploadWakePolicy.nextWait(for: makeSnapshot(batch: almostExpired), now: now)
        let waitFuture = UploadWakePolicy.nextWait(for: makeSnapshot(batch: futureClockSkew), now: now)

        #expect(waitHalf == 1.5)
        #expect(waitAlmost == 0.25)
        #expect(waitFuture == UploadWakePolicy.completionBannerDuration)
        #expect(UploadWakePolicy.showsProgress(for: halfSecondAgo, now: now))
        #expect(!UploadWakePolicy.showsProgress(for: halfSecondAgo, now: now.addingTimeInterval(1.5)))
    }

}

extension UploadWakePolicyTests {
    @Test("Active uploading and preparing items return 1-second tick")
    func uploadingAndPreparingReturnActiveInterval() {
        let uploading = makeSnapshot(pending: [makeItem(phase: .uploading)])
        let preparing = makeSnapshot(pending: [makeItem(phase: .preparing)])
        let mixed = makeSnapshot(pending: [
            makeItem(id: "verifying", phase: .verifying),
            makeItem(id: "uploading", phase: .uploading),
            makeItem(
                id: "retry",
                phase: .scheduled,
                resources: [makeResource(retryAfter: now.addingTimeInterval(10))]),
        ])

        #expect(UploadWakePolicy.nextWait(for: uploading, now: now) == UploadWakePolicy.activeInterval)
        #expect(UploadWakePolicy.nextWait(for: preparing, now: now) == UploadWakePolicy.activeInterval)
        #expect(UploadWakePolicy.nextWait(for: mixed, now: now) == UploadWakePolicy.activeInterval)
    }

    @Test("Verifying-only items return 2-second tick")
    func verifyingReturnsTwoSecondTick() {
        let verifying = makeSnapshot(pending: [makeItem(phase: .verifying)])
        let verifyingWithRetry = makeSnapshot(pending: [
            makeItem(id: "verifying", phase: .verifying),
            makeItem(
                id: "retry",
                phase: .scheduled,
                resources: [makeResource(retryAfter: now.addingTimeInterval(9))]),
        ])

        #expect(UploadWakePolicy.nextWait(for: verifying, now: now) == UploadWakePolicy.verifyingInterval)
        #expect(UploadWakePolicy.nextWait(for: verifyingWithRetry, now: now) == UploadWakePolicy.verifyingInterval)
    }

    @Test("Future retryAfter returns bounded deadline clamped to 2...15s")
    func futureRetryAfterReturnsBoundedDeadline() {
        let shortRetry = makeSnapshot(pending: [
            makeItem(phase: .scheduled, resources: [makeResource(retryAfter: now.addingTimeInterval(0.5))])
        ])
        let midRetry = makeSnapshot(pending: [
            makeItem(phase: .scheduled, resources: [makeResource(retryAfter: now.addingTimeInterval(7.5))])
        ])
        let longRetry = makeSnapshot(pending: [
            makeItem(phase: .scheduled, resources: [makeResource(retryAfter: now.addingTimeInterval(120))])
        ])
        let multipleRetries = makeSnapshot(pending: [
            makeItem(id: "late", phase: .scheduled, resources: [makeResource(retryAfter: now.addingTimeInterval(12))]),
            makeItem(id: "soon", phase: .scheduled, resources: [makeResource(retryAfter: now.addingTimeInterval(5))]),
        ])
        let readyPhoto = makeResource(id: "photo", phase: .ready, retryAfter: nil)
        let waitingPhoto = makeResource(id: "photo", phase: .scheduled, retryAfter: nil)
        let delayedVideo = makeResource(id: "video", phase: .scheduled, retryAfter: now.addingTimeInterval(9))
        let livePhotoWaiting = makeSnapshot(
            pending: [makeItem(phase: .scheduled, resources: [readyPhoto, delayedVideo])])
        let livePhotoPartiallyReady = makeSnapshot(
            pending: [makeItem(phase: .scheduled, resources: [waitingPhoto, delayedVideo])])

        #expect(UploadWakePolicy.nextWait(for: shortRetry, now: now) == UploadWakePolicy.minRetryInterval)
        #expect(UploadWakePolicy.nextWait(for: midRetry, now: now) == 7.5)
        #expect(UploadWakePolicy.nextWait(for: longRetry, now: now) == UploadWakePolicy.maxRetryInterval)
        #expect(UploadWakePolicy.nextWait(for: multipleRetries, now: now) == 5)
        #expect(UploadWakePolicy.nextWait(for: livePhotoWaiting, now: now) == 9)
        #expect(UploadWakePolicy.nextWait(for: livePhotoPartiallyReady, now: now) == UploadWakePolicy.scheduledInterval)
    }

    @Test("Coordinator retry backoff wakes within bounded 2...15s window")
    func coordinatorRetryBackoffIsBounded() {
        let queued = makeSnapshot(pending: [makeItem(phase: .queued)])
        let uploading = makeSnapshot(pending: [makeItem(phase: .uploading)])

        let waitMid = UploadWakePolicy.nextWait(
            for: queued, now: now, coordinatorRetryAt: now.addingTimeInterval(8))
        let waitLong = UploadWakePolicy.nextWait(
            for: queued, now: now, coordinatorRetryAt: now.addingTimeInterval(90))
        let waitUploading = UploadWakePolicy.nextWait(
            for: uploading, now: now, coordinatorRetryAt: now.addingTimeInterval(8))

        #expect(waitMid == 8)
        #expect(waitLong == UploadWakePolicy.maxRetryInterval)
        #expect(waitUploading == UploadWakePolicy.activeInterval)
    }

    @Test("Scheduled and queued items with canTransfer never park forever")
    func scheduledAndQueuedWithCanTransferDoNotParkForever() throws {
        let scheduled = makeSnapshot(pending: [makeItem(phase: .scheduled)])
        let queued = makeSnapshot(pending: [makeItem(phase: .queued)])
        let pastRetry = makeSnapshot(pending: [
            makeItem(phase: .scheduled, resources: [makeResource(retryAfter: now.addingTimeInterval(-5))])
        ])
        let truncatedPending = makeSnapshot(pending: [], pendingCount: 3)

        let scheduledWait = try #require(UploadWakePolicy.nextWait(for: scheduled, now: now))
        let queuedWait = try #require(UploadWakePolicy.nextWait(for: queued, now: now))
        let pastRetryWait = try #require(UploadWakePolicy.nextWait(for: pastRetry, now: now))
        let truncatedWait = try #require(UploadWakePolicy.nextWait(for: truncatedPending, now: now))

        #expect(scheduledWait == UploadWakePolicy.scheduledInterval)
        #expect(queuedWait == UploadWakePolicy.scheduledInterval)
        #expect(pastRetryWait == UploadWakePolicy.scheduledInterval)
        #expect(truncatedWait == UploadWakePolicy.scheduledInterval)
    }

    @Test("Disallowed network parks idle unless completion banner is active")
    func disallowedNetworkParksIdle() {
        let queuedOffline = makeSnapshot(policy: .wiFiOnly, pending: [makeItem(phase: .queued)])
        let recentlyCompletedOffline = makeSnapshot(
            policy: .wiFiOnly,
            batch: makeBatch(completedAt: now.addingTimeInterval(-1)))

        #expect(UploadWakePolicy.nextWait(for: queuedOffline, now: now, allowsNetwork: false) == nil)
        #expect(UploadWakePolicy.nextWait(for: recentlyCompletedOffline, now: now, allowsNetwork: false) == 1)
    }

    @Test("Active scanning or in-flight work ticks at 1 second only when transfers can run")
    func scanningAndInFlightWorkTickOnlyWhenCanTransfer() {
        let scanning = makeSnapshot(scanning: true)
        let working = makeSnapshot(pending: [])
        let pausedScanning = makeSnapshot(paused: true, scanning: true)
        let disabledWorking = makeSnapshot(policy: .disabled)

        #expect(UploadWakePolicy.nextWait(for: scanning, now: now) == UploadWakePolicy.activeInterval)
        #expect(UploadWakePolicy.nextWait(for: working, now: now, isWorking: true) == UploadWakePolicy.activeInterval)
        #expect(UploadWakePolicy.nextWait(for: pausedScanning, now: now, isWorking: true) == nil)
        #expect(UploadWakePolicy.nextWait(for: disabledWorking, now: now, isWorking: true) == nil)
    }

    @Test("Periodic discovery runs every 15s only while enabled and active")
    func periodicDiscoveryRules() {
        let disabled = makeSnapshot(policy: .disabled, pending: [makeItem(phase: .uploading)])
        let paused = makeSnapshot(policy: .allNetworks, paused: true, pending: [makeItem(phase: .queued)])
        let drained = makeSnapshot(policy: .allNetworks, pending: [])
        let active = makeSnapshot(policy: .allNetworks, pending: [makeItem(phase: .uploading)])

        #expect(!UploadWakePolicy.shouldDiscover(for: disabled, needsDiscovery: true, lastDiscovery: nil, now: now))
        #expect(UploadWakePolicy.shouldDiscover(for: paused, needsDiscovery: true, lastDiscovery: nil, now: now))
        #expect(
            !UploadWakePolicy.shouldDiscover(
                for: paused, needsDiscovery: false, lastDiscovery: now.addingTimeInterval(-60), now: now))
        #expect(UploadWakePolicy.shouldDiscover(for: drained, needsDiscovery: true, lastDiscovery: now, now: now))
        #expect(
            !UploadWakePolicy.shouldDiscover(
                for: drained, needsDiscovery: false, lastDiscovery: now.addingTimeInterval(-60), now: now))
        #expect(
            !UploadWakePolicy.shouldDiscover(
                for: active, needsDiscovery: false, lastDiscovery: now.addingTimeInterval(-14), now: now))
        #expect(
            UploadWakePolicy.shouldDiscover(
                for: active, needsDiscovery: false, lastDiscovery: now.addingTimeInterval(-15), now: now))
    }

    @Test("Wake gate preserves pre-wait wakeups and coalesces multiple signals")
    @MainActor
    func wakeGatePreservesAndCoalescesPreWaitSignals() async {
        let gate = UploadWakeGate(minimumSleep: 0.01)
        gate.wake()
        gate.wake()

        let first = await gate.wait(timeout: nil)
        let second = await gate.wait(timeout: 0.02)

        #expect(first == .woken)
        #expect(second == .timedOut)
    }

    @Test("Wake gate wakes parked waiter immediately and cancels timeout cleanly")
    @MainActor
    func wakeGateWakesParkedAndTimedWaiters() async {
        let gate = UploadWakeGate(minimumSleep: 0.01)

        let parkedTask = Task { @MainActor in
            await gate.wait(timeout: nil)
        }
        await Task.yield()
        gate.wake()
        #expect(await parkedTask.value == .woken)

        let timedTask = Task { @MainActor in
            await gate.wait(timeout: 10)
        }
        await Task.yield()
        gate.wake()
        #expect(await timedTask.value == .woken)
    }

    @Test("Wake gate exits cleanly when cancelled")
    @MainActor
    func wakeGateCancelsCleanly() async {
        let gate = UploadWakeGate(minimumSleep: 0.01)
        let task = Task { @MainActor in
            await gate.wait(timeout: nil)
        }
        await Task.yield()
        task.cancel()
        #expect(await task.value == .cancelled)
    }
}
