// Host side of `flutter drive` for the integration tests (profile-mode runs on a real phone, e.g. the map benchmark).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
