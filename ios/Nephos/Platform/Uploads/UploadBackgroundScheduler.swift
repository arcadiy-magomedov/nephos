import BackgroundTasks
import OSLog
import UIKit

enum UploadBackgroundScheduler {
    static let refreshID = "app.nephos.ios.upload-refresh"
    static let processingID = "app.nephos.ios.upload-processing"
    private static let logger = Logger(subsystem: "app.nephos.ios", category: "UploadScheduler")

    @MainActor
    static func register() {
        for id in [refreshID, processingID] {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                schedule()
                let completion = UploadCompletionGate()
                let operation = Task { @MainActor in
                    await UploadModel.shared.backgroundCheck()
                    if completion.claim() { task.setTaskCompleted(success: !Task.isCancelled) }
                }
                task.expirationHandler = {
                    operation.cancel()
                    if completion.claim() { task.setTaskCompleted(success: false) }
                }
            }
            if !registered { logger.error("Background upload task registration failed: \(id)") }
        }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        for request: BGTaskRequest in [refresh, processing] {
            do { try BGTaskScheduler.shared.submit(request) } catch {
                logger.error("Background upload scheduling failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingID)
    }
}

final class UploadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UploadBackgroundScheduler.register()
        UploadModel.shared.activate()
        return true
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == UploadModel.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        UploadModel.shared.handleBackgroundEvents(completion: completionHandler)
    }
}
