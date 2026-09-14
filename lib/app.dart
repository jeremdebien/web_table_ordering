import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'features/menu/presentation/bloc/menu_bloc.dart';
import 'features/table/presentation/bloc/table_bloc.dart';
import 'features/orders/presentation/bloc/cart_bloc.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'core/di/injection_container.dart' as di;
import 'core/services/reload_signal_service.dart';

class MyApp extends StatefulWidget {
  final GoRouter router;

  const MyApp({super.key, required this.router});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    // Always-on listener so a staff "Reload all" signal reaches this client
    // instantly (web only; a no-op elsewhere).
    di.sl<ReloadSignalService>().start();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<MenuBloc>(
          create: (context) => di.sl<MenuBloc>()..add(LoadMenu()),
        ),
        BlocProvider<TableBloc>(create: (context) => di.sl<TableBloc>()),
        BlocProvider<CartBloc>(create: (context) => di.sl<CartBloc>()),
        BlocProvider<AuthBloc>(
          create: (context) => di.sl<AuthBloc>()..add(const AuthCheckSession()),
        ),
      ],
      // The HTML loading splash (web/index.html) is dismissed by each cold-entry
      // page via SplashDismisser, once that page's background image has decoded,
      // so there is no blank gap between the splash and the first painted frame.
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'Web Table Ordering',
        routerConfig: widget.router,
        theme: ThemeData(
          // Dark default so the brief gap between the HTML splash and the first
          // painted page (background images / bloc data still loading) is
          // seamless with the splash instead of flashing white.
          scaffoldBackgroundColor: const Color(0xFF121212),
          fontFamily: 'Roboto',
        ),
      ),
    );
  }
}
