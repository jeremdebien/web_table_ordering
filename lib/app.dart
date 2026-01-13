import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/router/app_router.dart';
import 'features/table/presentation/cubit/table_context_cubit.dart';
import 'core/di/injection_container.dart' as di;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [BlocProvider<TableContextCubit>(create: (context) => di.sl<TableContextCubit>())],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'Web Table Ordering',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple), useMaterial3: true),
        routerConfig: appRouter,
      ),
    );
  }
}
