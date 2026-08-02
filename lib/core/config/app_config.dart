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

  /// Compile-time configuration, injected via `--dart-define-from-file=.env`.
  /// These take priority so web / production builds do NOT depend on fetching
  /// the `.env` asset over HTTP at runtime (IIS and other static hosts often
  /// refuse to serve a `.env` file, which left the config empty and sent
  /// Supabase calls to the page origin). Values fall back to dotenv (the
  /// bundled `.env`) so `flutter run` keeps working without extra flags.
  static const Map<String, String> _defines = {
    'APP_MODE': String.fromEnvironment('APP_MODE'),
    'ONLINE_SUPABASE_URL': String.fromEnvironment('ONLINE_SUPABASE_URL'),
    'ONLINE_SUPABASE_ANON_KEY': String.fromEnvironment('ONLINE_SUPABASE_ANON_KEY'),
    'ONLINE_IMAGE_STORAGE_PATH': String.fromEnvironment('ONLINE_IMAGE_STORAGE_PATH'),
    'LOCAL_SUPABASE_URL': String.fromEnvironment('LOCAL_SUPABASE_URL'),
    'LOCAL_SUPABASE_ANON_KEY': String.fromEnvironment('LOCAL_SUPABASE_ANON_KEY'),
    'LOCAL_IMAGE_STORAGE_PATH': String.fromEnvironment('LOCAL_IMAGE_STORAGE_PATH'),
    'POS_CLIENT_ID': String.fromEnvironment('POS_CLIENT_ID'),
    'BRANCH_ID': String.fromEnvironment('BRANCH_ID'),
    'ORDER_TYPE_CODE': String.fromEnvironment('ORDER_TYPE_CODE'),
  };

  static String _env(String key) {
    final fromDefine = _defines[key];
    if (fromDefine != null && fromDefine.isNotEmpty) return fromDefine;
    return dotenv.env[key] ?? '';
  }

  static AppMode get mode =>
      _env('APP_MODE').toLowerCase() == 'local' ? AppMode.local : AppMode.online;

  static bool get isLocal => mode == AppMode.local;

  static String get supabaseUrl =>
      isLocal ? _env('LOCAL_SUPABASE_URL') : _env('ONLINE_SUPABASE_URL');

  static String get supabaseAnonKey =>
      isLocal ? _env('LOCAL_SUPABASE_ANON_KEY') : _env('ONLINE_SUPABASE_ANON_KEY');

  /// Base URL for public Storage objects, ending in `.../object/public/`.
  ///
  /// In local mode this is derived from [supabaseUrl] so there is a single URL
  /// to configure — the local Supabase serves Storage from its own origin, so
  /// changing `LOCAL_SUPABASE_URL` moves images with it. (The old, separate
  /// `LOCAL_IMAGE_STORAGE_PATH` env var is no longer used and can be removed.)
  static String get imageStoragePath {
    if (!isLocal) return _env('ONLINE_IMAGE_STORAGE_PATH');
    final base = supabaseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/storage/v1/object/public/';
  }

  /// pos_clients.client_id stamped on locally-written order rows.
  static String get posClientId => _env('POS_CLIENT_ID');

  static int get orderTypeCode => int.tryParse(_env('ORDER_TYPE_CODE')) ?? 0;

  /// Branch filter — online mode only; the local DB is single-branch.
  static int get branchId => int.tryParse(_env('BRANCH_ID')) ?? 0;
}
