import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../features/home/presentation/pages/home_page.dart';
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
    GoRoute(path: '/', builder: (context, state) => const HomePage()),
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
