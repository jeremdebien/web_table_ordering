import 'package:flutter/material.dart';
import 'app.dart';
import 'bootstrap.dart';
import 'core/router/app_router.dart';

/// Android self-order kiosk entrypoint. Opens straight onto the menu; the
/// table and customer name are asked for at "Place Order".
///
///   flutter build apk -t lib/main_kiosk.dart
void main() async {
  await bootstrap();

  runApp(MyApp(router: buildRouter(kiosk: true)));
}
