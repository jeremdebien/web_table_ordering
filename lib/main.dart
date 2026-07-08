import 'package:flutter/material.dart';
import 'package:url_strategy/url_strategy.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'core/config/app_config.dart';
import 'core/di/injection_container.dart' as di;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clean URL setup for web
  setPathUrlStrategy();

  // Load environment variables
  await dotenv.load(fileName: ".env");
  // Initialize Supabase for the active app mode (online vs. local)
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  // Dependency Injection initialization
  await di.init();

  runApp(const MyApp());
}
