import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:web_table_ordering/features/menu/presentation/bloc/menu_bloc.dart';
import 'package:web_table_ordering/features/orders/presentation/bloc/cart_bloc.dart';
import 'package:web_table_ordering/features/orders/data/models/sales_order_item_model.dart';
import '../../../../features/orders/presentation/widgets/order_summary.dart';

class MenuPage extends StatelessWidget {
  const MenuPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
