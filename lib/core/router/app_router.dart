import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/pages/root_gate.dart';
import '../../features/menu_admin/presentation/bloc/menu_admin_bloc.dart';
import '../../features/menu_admin/presentation/pages/menu_admin_page.dart';
import '../../features/clear_orders/presentation/bloc/clear_orders_bloc.dart';
import '../../features/clear_orders/presentation/pages/clear_orders_page.dart';
import '../../features/home/presentation/pages/welcome_page.dart';
// TableEvent is now part of TableBloc, so no separate import needed if TableBloc is imported.
import '../../features/table/presentation/bloc/table_bloc.dart';
import '../../features/menu/presentation/pages/menu_page.dart';
import '../../features/table/presentation/pages/table_page.dart';
import '../../features/orders/presentation/pages/order_summary_page.dart';
import '../pages/not_found_page.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  errorBuilder: (context, state) => const NotFoundPage(),
  routes: [
    GoRoute(path: '/', builder: (context, state) => const WelcomePage()),
    GoRoute(
      path: '/staff',
      builder: (context, state) => const RootGate(),
      routes: [
        // Staff menu-visibility curation. Gated behind the same waiter session
        // as `/staff`; unauthenticated hits fall back to the PIN login.
        GoRoute(
          path: 'menu',
          builder: (context, state) => BlocBuilder<AuthBloc, AuthState>(
            builder: (context, authState) {
              if (authState is! AuthAuthenticated) return const RootGate();
              return BlocProvider(
                create: (_) => GetIt.instance<MenuAdminBloc>()..add(const LoadCuration()),
                child: const MenuAdminPage(),
              );
            },
          ),
        ),
        // Staff clear-orders floor plan. Same waiter-session gate as `/staff`.
        GoRoute(
          path: 'tables',
          builder: (context, state) => BlocBuilder<AuthBloc, AuthState>(
            builder: (context, authState) {
              if (authState is! AuthAuthenticated) return const RootGate();
              return BlocProvider(
                create: (_) => GetIt.instance<ClearOrdersBloc>()..add(const LoadTables()),
                child: const ClearOrdersPage(),
              );
            },
          ),
        ),
      ],
    ),
    GoRoute(
      path: '/table/:uuid',
      routes: [
        GoRoute(
          path: 'menu',
          builder: (context, state) => const MenuPage(),
        ),
        GoRoute(
          path: 'order_summary',
          builder: (context, state) => const OrderSummaryPage(),
        ),
      ],
      builder: (context, state) {
        final uuid = state.pathParameters['uuid']!;
        // Load table context
        context.read<TableBloc>().add(GetTable(uuid));
        return const TablePage();
      },
    ),
    GoRoute(
      path: '/404',
      builder: (context, state) => const NotFoundPage(),
    ),
  ],
);
