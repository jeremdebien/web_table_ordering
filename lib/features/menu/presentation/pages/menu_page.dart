import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:web_table_ordering/features/menu/presentation/bloc/menu_bloc.dart';
import 'package:web_table_ordering/features/orders/presentation/bloc/cart_bloc.dart';
import 'package:web_table_ordering/features/orders/data/models/sales_order_item_model.dart';
import 'package:web_table_ordering/features/table/presentation/bloc/table_bloc.dart';
import '../../../../features/orders/presentation/widgets/order_summary.dart';

class MenuPage extends StatefulWidget {
  const MenuPage({super.key});

  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> {
  @override
  void initState() {
    super.initState();
    _loadActiveOrder();
  }

  void _loadActiveOrder() {
    final tableState = context.read<TableBloc>().state;
    if (tableState is TableLoaded) {
      context.read<CartBloc>().add(LoadActiveOrder(tableState.table.tableId));
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
          title: const Text('Menu'),
        ),
        floatingActionButton: BlocBuilder<CartBloc, CartState>(
          builder: (context, state) {
            if (state.items.isEmpty) return const SizedBox.shrink();
            final totalCount = state.items.fold(0, (sum, item) => sum + item.quantity);
            return FloatingActionButton.extended(
              onPressed: () => _showOrderSummary(context),
              label: Text('View Order ($totalCount)'),
              icon: const Icon(Icons.shopping_cart),
            );
          },
        ),
        body: BlocBuilder<MenuBloc, MenuState>(
          builder: (context, state) {
            if (state is MenuLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is MenuError) {
              return Center(child: Text(state.message));
            }
            if (state is MenuLoaded) {
              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Categories: ${state.categories.length}'),
                      Text('Items: ${state.items.length}'),
                    ],
                  ),
                  SizedBox(
                    height: 50,
                    child: ListView.builder(
                      itemCount: state.categories.length,
                      scrollDirection: Axis.horizontal,
                      itemBuilder: (context, index) {
                        final category = state.categories[index];
                        final isSelected = category.categoryId == state.selectedCategoryId;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4.0),
                          child: ChoiceChip(
                            label: Text(category.name),
                            selected: isSelected,
                            onSelected: (selected) {
                              if (selected) {
                                context.read<MenuBloc>().add(SelectCategory(category.categoryId ?? 0));
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        childAspectRatio: 0.8,
                      ),
                      itemCount: state.items.where((item) => item.categoryId == state.selectedCategoryId).length,
                      itemBuilder: (context, index) {
                        final filteredItems = state.items
                            .where((item) => item.categoryId == state.selectedCategoryId)
                            .toList();
                        final item = filteredItems[index];
                        return InkWell(
                          onTap: () {
                            context.read<CartBloc>().add(
                              AddToCart(
                                SalesOrderItemModel(
                                  itemBarcode: item.barcode,
                                  itemName: item.name,
                                  quantity: 1,
                                  amount: item.price,
                                  originalQuantity: 0, // Ensure strictly 0 for new items
                                ),
                              ),
                            );
                          },
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    item.name,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  Text('${item.price}'),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  void _showOrderSummary(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return const OrderSummary();
      },
    );
  }
}
