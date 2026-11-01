import BackgroundTasks
import SwiftUI
import UIKit

final class BackgroundCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    func finish(success: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    var model: AppModel?
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = BackgroundTransfers.shared
        _ = NetworkPolicy.shared
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.backgroundID, using: nil) { [weak self] task in
            Task { @MainActor in
                guard let model = self?.model else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let completion = BackgroundCompletion(task)
                let work = Task { @MainActor in
                    await model.restore()
                    await model.runBackup()
                    completion.finish(success: !Task.isCancelled)
                }
                task.expirationHandler = {
                    work.cancel()
                    completion.finish(success: false)
                }
            }
        }
        return true
    }
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTransfers.identifier else {
            completionHandler()
            return
        }
        BackgroundTransfers.shared.finishedEvents = completionHandler
    }
}

@main
struct NephosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .modifier(AppAppearanceModifier())
                .privacySensitive()
                .overlay {
                    if scenePhase != .active {
                        ZStack {
                            Color(.systemBackground)
                            Label("Nephos", systemImage: "lock.shield").font(.title)
                        }
                        .ignoresSafeArea()
                    }
                }
                .task {
                    delegate.model = model
                    await model.restore()
                    if scenePhase == .active { model.scheduleAutomaticRun() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.updatePhotosStatus()
                        model.scheduleAutomaticRun()
                    }
                    if phase == .background {
                        model.scheduleBackground()
                        Task { await model.flushPersistence() }
                    }
                }
                .onChange(of: NetworkPolicy.shared.isConnected) { _, connected in
                    if connected && scenePhase == .active { model.scheduleAutomaticRun() }
                }
                .onChange(of: NetworkPolicy.shared.isExpensive) { _, expensive in
                    if !expensive && scenePhase == .active { model.scheduleAutomaticRun() }
                }
                .onChange(of: NetworkPolicy.shared.isConstrained) { _, constrained in
                    if !constrained && scenePhase == .active { model.scheduleAutomaticRun() }
                }
        }
    }
}
