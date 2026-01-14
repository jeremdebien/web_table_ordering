import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/cart_bloc.dart';
import '../../../table/presentation/bloc/table_bloc.dart';

class OrderSummary extends StatelessWidget {
  const OrderSummary({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CartBloc, CartState>(
      listener: (context, state) {
        if (state.status == CartStatus.success) {
          debugPrint('Order submitted successfully!');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Order submitted successfully!')),
          );
        } else if (state.status == CartStatus.failure) {
          debugPrint('Failed to submit order: ${state.errorMessage}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to submit order: ${state.errorMessage}')),
          );
        }
      },
      builder: (context, state) {
        return Container(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Order Summary',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const Divider(),
              if (state.items.isEmpty) const Expanded(child: Center(child: Text('Your cart is empty'))),
              if (state.items.isNotEmpty)
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Old Items Section
                        if (state.items.any((i) => i.originalQuantity > 0)) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8.0),
                            child: Text(
                              'Order:',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                            ),
                          ),
                          ...state.items.where((i) => i.originalQuantity > 0).map((item) {
                            return ListTile(
                              title: Text(item.itemName.isEmpty ? 'Unknown Item' : item.itemName),
                              subtitle: Text('${item.quantity} x ${item.unitPrice.toStringAsFixed(2)}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${item.amount.toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  // Old items are read-only and cannot be deleted from the cart
                                ],
                              ),
                            );
                          }),
                        ],

                        // Divider if both exist
                        if (state.items.any((i) => i.originalQuantity > 0) &&
                            state.items.any((i) => i.originalQuantity == 0))
                          const Divider(),

                        // New Items Section
                        if (state.items.any((i) => i.originalQuantity == 0)) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8.0),
                            child: Text(
                              'Additional Order:',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue),
                            ),
                          ),
                          ...state.items.where((i) => i.originalQuantity == 0).map((item) {
                            return ListTile(
                              title: Text(item.itemName),
                              subtitle: Text('${item.quantity} x ${item.unitPrice.toStringAsFixed(2)}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${item.amount.toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, color: Colors.red),
                                    onPressed: () {
                                      context.read<CartBloc>().add(RemoveFromCart(item));
                                    },
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total:',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${state.totalAmount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: state.items.isEmpty
                      ? null
                      : () {
                          final tableState = context.read<TableBloc>().state;
                          if (tableState is TableLoaded) {
                            showDialog(
                              context: context,
                              builder: (BuildContext dialogContext) {
                                return AlertDialog(
                                  title: const Text('Confirm Order'),
                                  content: const Text('Are you sure you want to place this order?'),
                                  actions: <Widget>[
                                    TextButton(
                                      child: const Text('Cancel'),
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                      },
                                    ),
                                    TextButton(
                                      child: const Text('Confirm'),
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        context.read<CartBloc>().add(
                                          SubmitOrder(
                                            tableId: tableState.table.tableId,
                                            guestCount: 1,
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                );
                              },
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Table info not available')),
                            );
                          }
                        },
                  child: state.status == CartStatus.loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Place Order'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
