import Flutter
import UIKit
import BackgroundTasks

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.blackvault.app.backgroundsync",
        using: nil
      ) { task in
        self.handleAppRefresh(task: task as! BGAppRefreshTask)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @available(iOS 13.0, *)
  private func handleAppRefresh(task: BGAppRefreshTask) {
    scheduleAppRefresh()

    task.expirationHandler = {
      task.setTaskCompleted(success: false)
    }

    task.setTaskCompleted(success: true)
  }

  @available(iOS 13.0, *)
  private func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: "com.blackvault.app.backgroundsync")
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Best-effort opportunistic scheduling
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
