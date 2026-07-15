import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../bloc/cart_bloc.dart';

/// Renders the stored special-instructions JSON as a compact human-readable
/// summary, e.g. "How done?: Rare • Notes: no salt". Returns null when empty.
String? formatSpecialInstructions(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return null;
    final parts = <String>[];
    for (final g in decoded) {
      final m = Map<String, dynamic>.from(g as Map);
      final label = (m['label'] as String?) ?? '';
      final choices = (m['choices'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
      final freeText = (m['free_text'] as String?)?.trim() ?? '';
      final answers = [...choices, if (freeText.isNotEmpty) freeText];
      if (answers.isEmpty) continue;
      parts.add(label.isEmpty ? answers.join(', ') : '$label: ${answers.join(', ')}');
    }
    return parts.isEmpty ? null : parts.join('  •  ');
  } catch (_) {
    return null;
  }
}

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
      subtitle: Builder(
        builder: (context) {
          final instructions = formatSpecialInstructions(item.specialInstructions);
          final priceLine = isCancelled
              ? Text(
                  'Quantity: ${item.quantity}',
                  style: const TextStyle(color: Colors.grey),
                )
              : Text('₱${item.amount.toStringAsFixed(2)}');
          if (instructions == null) return priceLine;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              priceLine,
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  instructions,
                  style: TextStyle(
                    fontSize: 11,
                    color: isCancelled ? Colors.grey : Colors.grey.shade700,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          );
        },
      ),
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
