import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';
import 'app.dart';
import 'core/di/injection_container.dart' as di;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clean URL setup for web
  setPathUrlStrategy();

  // Dependency Injection initialization
  await di.init();

  runApp(const MyApp());
}
