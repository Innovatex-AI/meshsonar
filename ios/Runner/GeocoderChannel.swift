import CoreLocation
import Flutter

/// Find sites wizard (lib/ui/plan/modes/wizard.dart, PlatformPlaceFinder): a ZIP code or address looked up on the phone.
/// The query goes to Apple's geocoder only, never to MeshSonar. Answers {lat, lon, label} or nil when nothing matched.
enum GeocoderChannel {
  private static let geocoder = CLGeocoder()

  static func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "app.meshsonar/geocoder", binaryMessenger: messenger).setMethodCallHandler { call, result in
      guard call.method == "geocode", let args = call.arguments as? [String: Any], let query = args["query"] as? String, !query.isEmpty else {
        result(FlutterMethodNotImplemented)
        return
      }
      geocoder.cancelGeocode()
      geocoder.geocodeAddressString(query) { placemarks, error in
        DispatchQueue.main.async {
          if let e = error as? CLError {
            switch e.code {
            case .geocodeFoundNoResult, .geocodeFoundPartialResult: result(nil)
            case .network: result(FlutterError(code: "network", message: nil, details: nil))
            default: result(FlutterError(code: "failed", message: nil, details: nil))
            }
            return
          }
          guard let p = placemarks?.first, let loc = p.location else { result(nil); return }
          let label = [p.locality, p.administrativeArea, p.postalCode].compactMap { $0 }.joined(separator: ", ")
          result(["lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude, "label": label])
        }
      }
    }
  }
}
