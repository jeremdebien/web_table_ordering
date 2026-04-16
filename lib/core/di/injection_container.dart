import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/device_id_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/menu/data/datasources/menu_supabase_datasource.dart';
import '../../features/menu/presentation/bloc/menu_bloc.dart';
import '../../features/orders/data/datasources/orders_supabase_datasource.dart';
import '../../features/table/data/datasources/table_supabase_datasource.dart';
import '../../features/table/presentation/bloc/table_bloc.dart';
import '../../features/orders/presentation/bloc/cart_bloc.dart';

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

  // Data sources
  sl.registerLazySingleton(() => MenuSupabaseDataSource(sl()));
  sl.registerLazySingleton(() => OrdersSupabaseDataSource(sl()));
  sl.registerLazySingleton(() => TableSupabaseDataSource(sl()));

  // Bloct
  sl.registerFactory(() => TableBloc(sl()));
  sl.registerFactory(() => CartBloc(sl(), sl(), sl()));

  // Core

  // External is registered at the top
}
