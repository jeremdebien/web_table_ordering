import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'core/di/injection_container.dart' as di;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clean URL setup for web
  setPathUrlStrategy();

  // Load environment variables
  await dotenv.load(fileName: ".env");
  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL'] ?? '',
    anonKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
  );

  // Dependency Injection initialization
  await di.init();

  runApp(const MyApp());
}
