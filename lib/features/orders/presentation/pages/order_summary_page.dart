import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
    return BlocListener<TableBloc, TableState>(
      listener: (context, state) {
        if (state is TableLoaded) {
          context.read<CartBloc>().add(LoadActiveOrder(state.table.tableId));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Order Summary'),
        ),
        body: const SafeArea(
          child: OrderSummary(isViewOnly: true),
        ),
      ),
    );
  }
}
