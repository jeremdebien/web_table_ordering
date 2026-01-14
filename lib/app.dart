import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/router/app_router.dart';
import 'features/menu/presentation/bloc/menu_bloc.dart';
import 'features/table/presentation/bloc/table_bloc.dart';
import 'features/orders/presentation/bloc/cart_bloc.dart';
import 'core/di/injection_container.dart' as di;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<MenuBloc>(
          create: (context) => di.sl<MenuBloc>()..add(LoadMenu()),
        ),
        BlocProvider<TableBloc>(create: (context) => di.sl<TableBloc>()),
        BlocProvider<CartBloc>(create: (context) => di.sl<CartBloc>()),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'Web Table Ordering',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple), useMaterial3: true),
        routerConfig: appRouter,
      ),
    );
  }
}
