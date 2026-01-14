import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/menu/data/datasources/menu_supabase_datasource.dart';
import '../../features/menu/presentation/bloc/menu_bloc.dart';
import '../../features/orders/data/datasources/orders_supabase_datasource.dart';
import '../../features/table/data/datasources/table_supabase_datasource.dart';
import '../../features/table/presentation/bloc/table_bloc.dart';

final sl = GetIt.instance;

Future<void> init() async {
  // Features - Home
  // Bloc
  sl.registerFactory(() => MenuBloc(sl()));

  // Use cases

  // Repository

  // Data sources
  sl.registerLazySingleton(() => MenuSupabaseDataSource(sl()));
  sl.registerLazySingleton(() => OrdersSupabaseDataSource(sl()));
  sl.registerLazySingleton(() => TableSupabaseDataSource(sl()));

  // Blocd
  sl.registerFactory(() => TableBloc(sl()));

  // Core

  // External
  sl.registerLazySingleton(() => Supabase.instance.client);
}
