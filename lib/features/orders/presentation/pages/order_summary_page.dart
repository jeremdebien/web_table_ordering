import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../table/presentation/bloc/table_bloc.dart';
import '../../../menu/presentation/bloc/menu_bloc.dart';
import '../bloc/cart_bloc.dart';
import '../widgets/order_summary.dart';

class OrderSummaryPage extends StatefulWidget {
  const OrderSummaryPage({super.key});

  @override
  State<OrderSummaryPage> createState() => _OrderSummaryPageState();
}

class _OrderSummaryPageState extends State<OrderSummaryPage> {
  @override
  void initState() {
    super.initState();
    _loadOrder();
  }

  void _loadOrder() {
    final tableState = context.read<TableBloc>().state;
    if (tableState is TableLoaded) {
      context.read<CartBloc>().add(LoadActiveOrder(tableState.table.tableId));
    }

    // Ensure menu is loaded to map item names
    final menuState = context.read<MenuBloc>().state;
    if (menuState is MenuInitial) {
      context.read<MenuBloc>().add(LoadMenu());
    }
  }

  @override
  Widget build(BuildContext context) {
    final uuid = GoRouterState.of(context).pathParameters['uuid'] ?? '';

    return BlocListener<TableBloc, TableState>(
      listener: (context, state) {
        if (state is TableLoaded) {
          context.read<CartBloc>().add(LoadActiveOrder(state.table.tableId));
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Container(
                    height: 200,
                    child: Image.asset(
                      'assets/images/logo.jpg',
                      fit: BoxFit.contain,
                    ),
                  ),
                  Expanded(
                    child: OrderSummary(isViewOnly: true),
                  ),
                ],
              ),
              Positioned(
                top: 16,
                left: 16,
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Color(0xfff25125),
                    shape: CircleBorder(),
                  ),
                  icon: Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 22,
                  ),
                  onPressed: () {
                    context.go('/table/$uuid');
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
