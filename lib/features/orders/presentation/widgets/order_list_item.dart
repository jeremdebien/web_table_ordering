import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../bloc/cart_bloc.dart';

class OrderListItem extends StatelessWidget {
  final SalesOrderItemModel item;
  final String? displayImage;

  const OrderListItem({
    super.key,
    required this.item,
    this.displayImage,
  });

  @override
  Widget build(BuildContext context) {
    // Determine styling based on status
    final isCancelled = item.status == 'Cancelled';
    final textStyle = isCancelled
        ? const TextStyle(
            decoration: TextDecoration.lineThrough,
            color: Colors.grey,
          )
        : null;

    final priceStyle = isCancelled
        ? const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.grey,
            decoration: TextDecoration.lineThrough,
          )
        : const TextStyle(fontWeight: FontWeight.bold);

    final quantityStyle = isCancelled
        ? const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            decoration: TextDecoration.lineThrough, // Added line trough for consistency
            color: Colors.grey,
          )
        : const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          );

    Widget buildImage() {
      if (displayImage != null && displayImage!.isNotEmpty) {
        return Image.network(
          displayImage!,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Image.asset(
              'assets/images/logo.jpg',
              width: 40,
              height: 40,
              fit: BoxFit.cover,
            );
          },
        );
      }
      return Image.asset(
        'assets/images/logo.jpg',
        width: 40,
        height: 40,
        fit: BoxFit.cover,
      );
    }

    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${item.quantity} x',
            style: quantityStyle,
          ),
          const SizedBox(width: 6),
          if (isCancelled)
            Opacity(
              opacity: 0.5,
              child: buildImage(),
            )
          else
            buildImage(),
        ],
      ),
      title: Text(
        item.itemName.isEmpty ? 'Unknown Item' : item.itemName,
        style: textStyle,
      ),
      subtitle: isCancelled
          ? Text(
              'Quantity: ${item.quantity}',
              style: const TextStyle(color: Colors.grey),
            )
          : Text('₱${item.amount.toStringAsFixed(2)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '₱${item.totalPrice.toStringAsFixed(2)}',
            style: priceStyle,
          ),
          if (item.originalQuantity == 0)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () {
                context.read<CartBloc>().add(
                  RemoveFromCart(item),
                );
              },
            ),
        ],
      ),
    );
  }
}
