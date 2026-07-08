import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Which backend the app talks to and how orders are written.
enum AppMode {
  /// Hosted Supabase. Orders flow through Edge Functions and a pending stage.
  online,

  /// Locally-hosted Supabase (local_supabase_migration schema). Orders are
  /// written directly to sales_order_2 / sales_order_item (no pending stage).
  local,
}

/// Single source of truth for environment-driven configuration.
///
/// Reads from the loaded `.env` (via flutter_dotenv) and resolves the active
/// connection + tuning values based on [mode].
class AppConfig {
  AppConfig._();

  static String _env(String key) => dotenv.env[key] ?? '';

  static AppMode get mode =>
      _env('APP_MODE').toLowerCase() == 'local' ? AppMode.local : AppMode.online;

  static bool get isLocal => mode == AppMode.local;

  static String get supabaseUrl =>
      isLocal ? _env('LOCAL_SUPABASE_URL') : _env('ONLINE_SUPABASE_URL');

  static String get supabaseAnonKey =>
      isLocal ? _env('LOCAL_SUPABASE_ANON_KEY') : _env('ONLINE_SUPABASE_ANON_KEY');

  static String get imageStoragePath =>
      isLocal ? _env('LOCAL_IMAGE_STORAGE_PATH') : _env('ONLINE_IMAGE_STORAGE_PATH');

  /// pos_clients.client_id stamped on locally-written order rows.
  static String get posClientId => _env('POS_CLIENT_ID');

  static int get orderTypeCode => int.tryParse(_env('ORDER_TYPE_CODE')) ?? 0;

  /// Branch filter — online mode only; the local DB is single-branch.
  static int get branchId => int.tryParse(_env('BRANCH_ID')) ?? 0;
}
