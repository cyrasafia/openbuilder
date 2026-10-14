import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var bgTasks: [Int: UIBackgroundTaskIdentifier] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.openbuilder.app/bg_task",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "delegate_gone", message: nil, details: nil))
        return
      }
      switch call.method {
      case "begin":
        let label = (call.arguments as? [String: Any])?["label"] as? String ?? "bg"
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: label) { [weak self] in
          if let self = self, taskID != .invalid {
            self.bgTasks.removeValue(forKey: Int(taskID.rawValue))
          }
          UIApplication.shared.endBackgroundTask(taskID)
          taskID = .invalid
        }
        if taskID == .invalid {
          result(nil)
        } else {
          self.bgTasks[Int(taskID.rawValue)] = taskID
          result(Int(taskID.rawValue))
        }
      case "end":
        if let args = call.arguments as? [String: Any],
           let raw = args["id"] as? Int,
           let task = self.bgTasks.removeValue(forKey: raw) {
          UIApplication.shared.endBackgroundTask(task)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
