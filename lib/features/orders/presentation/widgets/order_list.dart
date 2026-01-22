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
            // Pending Orders Section
            if (items.any((i) => i.originalQuantity > 0 && i.status == 'Pending')) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Pending Order:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange),
                ),
              ),
              ...items.where((i) => i.originalQuantity > 0 && i.status == 'Pending').map((item) {
                return ListTile(
                  leading: Image.asset('assets/images/sample.webp', width: 40, height: 40, fit: BoxFit.cover),
                  title: Text(item.itemName.isEmpty ? 'Unknown Item' : item.itemName),
                  subtitle: Text('Quantity: ${item.quantity}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '₱${item.totalPrice.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(),
            ],

            // Cancelled Orders Section
            if (items.any((i) => i.originalQuantity > 0 && i.status == 'Cancelled')) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Cancelled Order:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
              ),
              ...items.where((i) => i.originalQuantity > 0 && i.status == 'Cancelled').map((item) {
                return ListTile(
                  leading: Opacity(
                    opacity: 0.5,
                    child: Image.asset('assets/images/sample.webp', width: 40, height: 40, fit: BoxFit.cover),
                  ),
                  title: Text(
                    item.itemName.isEmpty ? 'Unknown Item' : item.itemName,
                    style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey),
                  ),
                  subtitle: Text('Quantity: ${item.quantity}', style: const TextStyle(color: Colors.grey)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '₱${item.totalPrice.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(),
            ],

            // Accepted Orders Section
            if (items.any((i) => i.originalQuantity > 0 && i.status == 'Accepted')) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Order:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green),
                ),
              ),
              ...items.where((i) => i.originalQuantity > 0 && i.status == 'Accepted').map((item) {
                return ListTile(
                  leading: Image.asset('assets/images/sample.webp', width: 40, height: 40, fit: BoxFit.cover),
                  title: Text(item.itemName.isEmpty ? 'Unknown Item' : item.itemName),
                  subtitle: Text('Quantity: ${item.quantity}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '₱${item.totalPrice.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              }),
            ],

            // Divider if Accepted and New exist
            if (items.any((i) => i.originalQuantity > 0 && i.status == 'Accepted') &&
                items.any((i) => i.originalQuantity == 0))
              const Divider(),

            // New Items (Additional Order) Section
            if (items.any((i) => i.originalQuantity == 0)) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Additional Order:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red),
                ),
              ),
              ...items.where((i) => i.originalQuantity == 0).map((item) {
                return ListTile(
                  leading: Image.asset('assets/images/sample.webp', width: 40, height: 40, fit: BoxFit.cover),
                  title: Text(item.itemName),
                  subtitle: Text('Quantity: ${item.quantity}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '₱${item.totalPrice.toStringAsFixed(2)}',
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
