import 'package:flutter/material.dart';
import 'app.dart';
import 'bootstrap.dart';
import 'core/router/app_router.dart';

/// Android waiter app entrypoint. Opens on the staff PIN login; once signed in
/// the waiter lands on the staff home (Add Order + settings).
///
///   flutter build apk -t lib/main_waiter.dart
void main() async {
  await bootstrap();

  runApp(MyApp(router: buildRouter(waiter: true)));
}
