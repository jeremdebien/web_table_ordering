import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../bloc/cart_bloc.dart';

class OrderList extends StatelessWidget {
  final List<SalesOrderItemModel> items;

  const OrderList({
    super.key,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Expanded(child: Center(child: Text('Your cart is empty')));
    }

    return Expanded(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Old Items Section
            if (items.any((i) => i.originalQuantity > 0)) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Order:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
              ),
              ...items.where((i) => i.originalQuantity > 0).map((item) {
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
            if (items.any((i) => i.originalQuantity > 0) && items.any((i) => i.originalQuantity == 0)) const Divider(),

            // New Items Section
            if (items.any((i) => i.originalQuantity == 0)) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Additional Order:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue),
                ),
              ),
              ...items.where((i) => i.originalQuantity == 0).map((item) {
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
    );
  }
}
