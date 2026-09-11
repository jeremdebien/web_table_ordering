import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';
import 'app.dart';
import 'bootstrap.dart';
import 'core/router/app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clean URL setup for web
  setPathUrlStrategy();

  await bootstrap();

  runApp(MyApp(router: buildRouter()));
}
