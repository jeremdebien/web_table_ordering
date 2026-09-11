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
import '../../features/kiosk/presentation/pages/kiosk_menu_page.dart';
// TableEvent is now part of TableBloc, so no separate import needed if TableBloc is imported.
import '../../features/table/presentation/bloc/table_bloc.dart';
import '../../features/menu/presentation/pages/menu_page.dart';
import '../../features/table/presentation/pages/table_page.dart';
import '../../features/table/presentation/pages/qr_resolver_page.dart';
import '../../features/orders/presentation/pages/order_summary_page.dart';
import '../pages/not_found_page.dart';

/// [kiosk] is the Android self-order build (`main_kiosk.dart`): `/` opens the
/// menu directly instead of the welcome page. Every other route is shared.
GoRouter buildRouter({bool kiosk = false}) => GoRouter(
  initialLocation: '/',
  errorBuilder: (context, state) => const NotFoundPage(),
  // Legacy QR codes point at the old POS URL shape
  // (`/app/NYX/index.php?...&table=c6&...`). Those printed codes can't be
  // regenerated, so we intercept any entry carrying a `table` query param and
  // hand it to the resolver, which turns the table name into its UUID and
  // forwards to `/table/:uuid`. See QrResolverPage.
  redirect: (context, state) {
    final tableName = state.uri.queryParameters['table'];
    if (tableName != null && tableName.trim().isNotEmpty && state.uri.path != '/qr') {
      return '/qr?table=${Uri.encodeQueryComponent(tableName)}';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => kiosk ? const KioskMenuPage() : const WelcomePage(),
    ),
    GoRoute(
      path: '/qr',
      builder: (context, state) => QrResolverPage(
        tableName: state.uri.queryParameters['table'] ?? '',
      ),
    ),
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
