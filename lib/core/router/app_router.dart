import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../features/home/presentation/pages/home_page.dart';
import '../../features/table/presentation/cubit/table_context_cubit.dart';
import '../../features/table/presentation/pages/table_page.dart';
import '../pages/not_found_page.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  errorBuilder: (context, state) => const NotFoundPage(),
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomePage()),
    GoRoute(
      path: '/table/:uuid',
      builder: (context, state) {
        final uuid = state.pathParameters['uuid']!;
        // Load table context
        context.read<TableContextCubit>().loadTable(uuid);
        return const TablePage();
      },
    ),
    GoRoute(
      path: '/404',
      builder: (context, state) => const NotFoundPage(),
    ),
  ],
);
