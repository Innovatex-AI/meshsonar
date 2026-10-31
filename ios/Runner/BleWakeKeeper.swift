// BleWakeKeeper: an EXPERIMENT for spike S1 (docs/BACKGROUND_BLE_SPIKE.md). Off unless the person arms it in
// Settings > Diagnostics > Background Bluetooth test.
//
// Why: flutter_reactive_ble (reactive_ble_mobile 5.4.1, darwin/Classes/ReactiveBle/Central.swift:124) creates its
// CBCentralManager with `queue: nil` and NO options: no CBCentralManagerOptionRestoreIdentifierKey, and no
// centralManager(_:willRestoreState:) anywhere in the plugin. So iOS cannot relaunch a closed app for the plugin's
// connection. This class is a second, minimal central that DOES have a restore identifier. It connects to the same radio
// (CoreBluetooth shares the link between centrals of one app), discovers the MeshCore UART service and subscribes to the TX
// characteristic. If iOS ends the app and the radio then notifies, iOS can relaunch the app for THIS central; Dart starts
// as usual and LaunchReconnect (lib/alerts/launch_reconnect.dart) brings the real link back and drains the radio's queue.
//
// It reads no message: it counts notifications and writes timestamped event lines to UserDefaults for the debug screen.
//
// UNPROVEN (nothing here has run on a device): (1) that two centrals in one app can both subscribe to the same
// characteristic and that the plugin's later unsubscribe does not switch notifications off for this one; (2) that iOS
// relaunches the app when only this central is subscribed; (3) that a pending connect survives a jetsam. The device
// matrix in the spike doc decides. If it fails, delete this file and the two channel registrations in AppDelegate.
import CoreBluetooth
import UIKit

final class BleWakeKeeper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  static let shared = BleWakeKeeper()

  private let restoreId = "app.meshsonar.ble-wake"
  private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
  private let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
  private let idKey = "bleWake.armedId"
  private let linesKey = "bleWake.lines"
  private let awayKey = "bleWake.notificationsWhileAway"
  private let defaults = UserDefaults.standard

  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private(set) var launchedByRestore = false

  private var armedId: String? {
    get { defaults.string(forKey: idKey) }
    set { defaults.set(newValue, forKey: idKey) }
  }

  // MARK: lifecycle

  /// Call from application(_:didFinishLaunchingWithOptions:). A central with a restore identifier must exist before the
  /// launch finishes, or the restoration callback is lost. Only when armed: otherwise this class does nothing at all.
  func startIfArmed() {
    guard armedId != nil else { return }
    log("launch", "armed, creating central with restore id")
    ensureCentral()
  }

  private func ensureCentral() {
    if central == nil {
      central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: restoreId])
    }
  }

  func arm(_ id: String) {
    armedId = id
    log("arm", "radio \(id.prefix(8))")
    ensureCentral()
    connectIfPossible()
  }

  func disarm() {
    log("disarm", "released")
    armedId = nil
    if let p = peripheral, let c = central { c.cancelPeripheralConnection(p) }
    peripheral = nil
  }

  func report() -> [String: Any] {
    return [
      "armed": armedId != nil,
      "launchedByRestore": launchedByRestore,
      "notificationsWhileAway": defaults.integer(forKey: awayKey),
      "lines": defaults.stringArray(forKey: linesKey) ?? [],
    ]
  }

  func clearReport() {
    defaults.removeObject(forKey: linesKey)
    defaults.set(0, forKey: awayKey)
  }

  private func log(_ kind: String, _ detail: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let state = UIApplication.shared.applicationState == .active ? "fg" : "bg"
    var lines = defaults.stringArray(forKey: linesKey) ?? []
    lines.append("native[\(f.string(from: Date())) \(state)] \(kind) \(detail)")
    if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    defaults.set(lines, forKey: linesKey)
  }

  // MARK: connecting

  private func connectIfPossible() {
    guard let c = central, c.state == .poweredOn, let id = armedId, let uuid = UUID(uuidString: id) else { return }
    if peripheral == nil {
      peripheral = c.retrievePeripherals(withIdentifiers: [uuid]).first
    }
    guard let p = peripheral else {
      log("connect", "peripheral unknown to CoreBluetooth")
      return
    }
    p.delegate = self
    switch p.state {
    case .connected:
      subscribe(p)
    case .disconnected:
      // No options: the NotifyOn* keys make the system show alerts, which we do not want. A pending connect has no timeout.
      c.connect(p, options: nil)
      log("connect", "requested (pending until the radio is reachable)")
    default:
      break
    }
  }

  private func subscribe(_ p: CBPeripheral) {
    if let svc = p.services?.first(where: { $0.uuid == serviceUUID }),
       let tx = svc.characteristics?.first(where: { $0.uuid == txUUID }) {
      if !tx.isNotifying { p.setNotifyValue(true, for: tx) }
      log("subscribe", "already discovered, notifying=\(tx.isNotifying)")
    } else {
      p.discoverServices([serviceUUID])
    }
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log("state", "central state \(central.state.rawValue)")
    if central.state == .poweredOn { connectIfPossible() }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    launchedByRestore = true
    let ps = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
    log("restore", "willRestoreState with \(ps.count) peripheral(s)")
    if let p = ps.first {
      peripheral = p
      p.delegate = self
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    log("connected", peripheral.identifier.uuidString.prefix(8).description)
    peripheral.delegate = self
    peripheral.discoverServices([serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    log("connect-failed", error?.localizedDescription ?? "")
    if armedId != nil { central.connect(peripheral, options: nil) }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    log("disconnected", error?.localizedDescription ?? "no error")
    // Keep a pending connect so a returning radio (or a relaunch) finds us.
    if armedId != nil { central.connect(peripheral, options: nil) }
  }

  // MARK: CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let svc = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
      log("discover", "UART service not found \(error?.localizedDescription ?? "")")
      return
    }
    peripheral.discoverCharacteristics([txUUID], for: svc)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let tx = service.characteristics?.first(where: { $0.uuid == txUUID }) else {
      log("discover", "TX characteristic not found")
      return
    }
    peripheral.setNotifyValue(true, for: tx)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    log("notify-state", "isNotifying=\(characteristic.isNotifying) \(error?.localizedDescription ?? "")")
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard characteristic.uuid == txUUID else { return }
    let away = UIApplication.shared.applicationState != .active
    if away {
      defaults.set(defaults.integer(forKey: awayKey) + 1, forKey: awayKey)
      log("notification", "while away, \(characteristic.value?.count ?? 0) bytes")
    }
  }
}
