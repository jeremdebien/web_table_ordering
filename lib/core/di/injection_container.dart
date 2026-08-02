import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/device_id_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../../features/menu/data/datasources/menu_data_source.dart';
import '../../features/menu/data/datasources/menu_online_datasource.dart';
import '../../features/menu/data/datasources/menu_local_datasource.dart';
import '../../features/menu/presentation/bloc/menu_bloc.dart';
import '../../features/orders/data/datasources/orders_data_source.dart';
import '../../features/orders/data/datasources/orders_online_datasource.dart';
import '../../features/orders/data/datasources/orders_local_datasource.dart';
import '../../features/table/data/datasources/table_data_source.dart';
import '../../features/table/data/datasources/table_online_datasource.dart';
import '../../features/table/data/datasources/table_local_datasource.dart';
import '../../features/table/presentation/bloc/table_bloc.dart';
import '../../features/orders/presentation/bloc/cart_bloc.dart';
import '../../features/auth/data/auth_session_store.dart';
import '../../features/auth/data/datasources/user_data_source.dart';
import '../../features/auth/data/datasources/local_user_data_source.dart';
import '../../features/auth/data/datasources/online_user_data_source.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';

final sl = GetIt.instance;

Future<void> init() async {
  // External
  final sharedPreferences = await SharedPreferences.getInstance();
  sl.registerLazySingleton(() => sharedPreferences);
  sl.registerLazySingleton(() => Supabase.instance.client);

  // Core
  sl.registerLazySingleton(() => DeviceIdService(sl()));
  // Features - Home
  sl.registerLazySingleton(() => MenuBloc(sl()));

  // Use cases

  // Repository

  // Data sources — implementation selected by the active app mode.
  sl.registerLazySingleton<MenuDataSource>(
    () => AppConfig.isLocal ? LocalMenuDataSource(sl()) : OnlineMenuDataSource(sl()),
  );
  sl.registerLazySingleton<OrdersDataSource>(
    () => AppConfig.isLocal ? LocalOrdersDataSource(sl()) : OnlineOrdersDataSource(sl()),
  );
  sl.registerLazySingleton<TableDataSource>(
    () => AppConfig.isLocal ? LocalTableDataSource(sl()) : OnlineTableDataSource(sl()),
  );
  sl.registerLazySingleton<UserDataSource>(
    () => AppConfig.isLocal ? LocalUserDataSource(sl()) : OnlineUserDataSource(),
  );

  // Auth session persistence (survives browser refresh)
  sl.registerLazySingleton(() => AuthSessionStore(sl()));

  // Bloct
  sl.registerFactory(() => TableBloc(sl()));
  sl.registerFactory(() => CartBloc(sl(), sl(), sl()));
  sl.registerLazySingleton(() => AuthBloc(sl(), sl()));

  // Core

  // External is registered at the top
}
