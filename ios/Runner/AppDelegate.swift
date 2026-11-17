import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // S1 experiment: only does anything when the person armed it (see BleWakeKeeper.swift).
    BleWakeKeeper.shared.startIfArmed()
    // flutter_local_notifications: taps and foreground presentation are delivered through the plugin.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "MeshSonarAlerts")?.messenger() else { return }

    HapticsChannel.register(messenger: messenger)
    GeocoderChannel.register(messenger: messenger)
    LowPowerModeChannel.register(messenger: messenger)

    // Badge count on the app icon (lib/platform/local_notifications_plugin.dart).
    FlutterMethodChannel(name: "app.meshsonar/alerts", binaryMessenger: messenger).setMethodCallHandler { call, result in
      if call.method == "setBadge", let n = call.arguments as? Int {
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
        } else {
          DispatchQueue.main.async { UIApplication.shared.applicationIconBadgeNumber = n }
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // The wake keeper experiment (lib/platform/ios_wake_keeper.dart).
    FlutterMethodChannel(name: "app.meshsonar/ble_wake", binaryMessenger: messenger).setMethodCallHandler { call, result in
      switch call.method {
      case "arm":
        if let id = call.arguments as? String { BleWakeKeeper.shared.arm(id) }
        result(nil)
      case "disarm":
        BleWakeKeeper.shared.disarm()
        result(nil)
      case "report":
        result(BleWakeKeeper.shared.report())
      case "clearReport":
        BleWakeKeeper.shared.clearReport()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// iPhone Low Power Mode for the battery profile (lib/platform/low_power_mode.dart): `isOn` answers the current state, the event
/// channel sends it once on listen and again on every NSProcessInfoPowerStateDidChange.
final class LowPowerModeChannel: NSObject, FlutterStreamHandler {
  private static var shared: LowPowerModeChannel?
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  static func register(messenger: FlutterBinaryMessenger) {
    let handler = LowPowerModeChannel()
    shared = handler
    FlutterMethodChannel(name: "meshsonar/power", binaryMessenger: messenger).setMethodCallHandler { call, result in
      if call.method == "isOn" {
        result(ProcessInfo.processInfo.isLowPowerModeEnabled)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(name: "meshsonar/power/events", binaryMessenger: messenger).setStreamHandler(handler)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    events(ProcessInfo.processInfo.isLowPowerModeEnabled)
    observer = NotificationCenter.default.addObserver(
      forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      self?.sink?(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    observer = nil
    sink = nil
    return nil
  }
}
