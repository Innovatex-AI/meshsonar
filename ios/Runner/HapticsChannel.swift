import Flutter
import UIKit

/// Notification and soft-impact haptics that Flutter's HapticFeedback does not expose
/// (lib/platform/haptics_channel.dart). Channel `app.meshsonar/haptics`.
final class HapticsChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    // Reduce Transparency (spike S10), lib/platform/accessibility_channel.dart.
    FlutterMethodChannel(name: "app.meshsonar/accessibility", binaryMessenger: messenger).setMethodCallHandler { call, result in
      if call.method == "reduceTransparency" { result(UIAccessibility.isReduceTransparencyEnabled) } else { result(FlutterMethodNotImplemented) }
    }
    FlutterMethodChannel(name: "app.meshsonar/haptics", binaryMessenger: messenger).setMethodCallHandler { call, result in
      guard let kind = call.arguments as? String else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "notify":
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        switch kind {
        case "success": g.notificationOccurred(.success)
        case "warning": g.notificationOccurred(.warning)
        default: g.notificationOccurred(.error)
        }
        result(nil)
      case "impact":
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch kind {
        case "light": style = .light
        case "medium": style = .medium
        default: style = .soft
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
