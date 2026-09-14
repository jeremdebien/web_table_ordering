import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../bloc/cart_bloc.dart';
import 'serving_status_badge.dart';

class CartItemTile extends StatelessWidget {
  final SalesOrderItemModel item;
  final String? displayImage;

  const CartItemTile({
    super.key,
    required this.item,
    this.displayImage,
  });

  @override
  Widget build(BuildContext context) {
    final isDraft = item.originalQuantity == 0;
    final specialInstructions = _formatSpecialInstructions(item.specialInstructions);
    final hasNote = item.note != null && item.note!.trim().isNotEmpty;
    final isServed = item.isServed;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isServed ? const Color(0xFFFAF9F6) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDraft
              ? const Color(0xFFC5A880).withValues(alpha: 0.35)
              : const Color(0xFFE8E5DF),
          width: isDraft ? 1.2 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Item Image Thumbnail
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFC5A880).withValues(alpha: 0.3),
                width: 1.2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  displayImage != null && displayImage!.isNotEmpty
                      ? Image.network(
                          displayImage!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: Colors.grey.shade100,
                            child: const Icon(
                              Icons.restaurant_rounded,
                              color: Colors.grey,
                              size: 28,
                            ),
                          ),
                        )
                      : Container(
                          color: Colors.grey.shade100,
                          child: const Icon(
                            Icons.restaurant_rounded,
                            color: Colors.grey,
                            size: 28,
                          ),
                        ),
                  if (isServed)
                    Container(
                      color: Colors.black.withValues(alpha: 0.15),
                      child: const Center(
                        child: Icon(
                          Icons.check_circle_rounded,
                          color: Color(0xFF2E7D32),
                          size: 24,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Main details column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Row: Item Name & Total Price
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.itemName.isEmpty ? 'Unknown Item' : item.itemName,
                        style: const TextStyle(
                          color: Color(0xFF1A1A1A),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '₱${(item.amount * item.quantity).toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Color(0xFF1A1A1A),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // Meta Badges Flow: Status pills, Guest name
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // Draft / To Order Badge
                    if (isDraft)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF9E6),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFFFD54F),
                            width: 0.8,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.add_shopping_cart_rounded,
                              size: 11,
                              color: Color(0xFFB78103),
                            ),
                            SizedBox(width: 3.5),
                            Text(
                              'To Order',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFB78103),
                                letterSpacing: 0.2,
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Live Kitchen Serving Status Badge
                    if (item.hasServingStatus)
                      ServingStatusBadge(item: item),

                    // Guest Nickname Pill
                    if (item.nickname.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2ECE4),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFD3C5B4),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.person_outline_rounded,
                              size: 11,
                              color: Color(0xFF6B5842),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              item.nickname,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Color(0xFF6B5842),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),

                // Special Instructions / Notes
                if (specialInstructions != null || hasNote) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F7F4),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 1.5, right: 4),
                          child: Icon(
                            Icons.edit_note_rounded,
                            size: 13,
                            color: Color(0xFF8A847C),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            [
                              if (specialInstructions != null) specialInstructions,
                              if (hasNote) item.note!.trim(),
                            ].join(' • '),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF635E58),
                              fontStyle: FontStyle.italic,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 8),

                // Bottom Row: Unit price on left, Stepper / Lock badge on right
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Unit Price
                    Text(
                      '₱${item.amount.toStringAsFixed(0)} each',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    // Stepper / Action Controls
                    if (isDraft)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Minus Button
                          Material(
                            color: const Color(0xFF1A1A1A),
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () {
                                if (item.quantity > 1) {
                                  context.read<CartBloc>().add(
                                    AddToCart(item.copyWith(quantity: -1)),
                                  );
                                } else {
                                  context.read<CartBloc>().add(RemoveFromCart(item));
                                }
                              },
                              child: const SizedBox(
                                width: 26,
                                height: 26,
                                child: Icon(
                                  Icons.remove,
                                  color: Colors.white,
                                  size: 15,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              '${item.quantity}',
                              style: const TextStyle(
                                color: Color(0xFF1A1A1A),
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          // Plus Button
                          Material(
                            color: Colors.white,
                            shape: CircleBorder(
                              side: BorderSide(color: Colors.grey.shade400, width: 1),
                            ),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () {
                                context.read<CartBloc>().add(
                                  AddToCart(item.copyWith(quantity: 1)),
                                );
                              },
                              child: const SizedBox(
                                width: 26,
                                height: 26,
                                child: Icon(
                                  Icons.add,
                                  color: Color(0xFF1A1A1A),
                                  size: 15,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Delete / Trash Icon
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                context.read<CartBloc>().add(RemoveFromCart(item));
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Icon(
                                  Icons.delete_outline_rounded,
                                  color: Colors.red.shade400,
                                  size: 19,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      // Submitted / Fixed Quantity Indicator
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F3EF),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0xFFE2DDD5),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.receipt_long_rounded,
                              size: 12,
                              color: Colors.grey.shade700,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Ordered: ${item.quantity}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.grey.shade800,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _formatSpecialInstructions(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;
      final parts = <String>[];
      for (final g in decoded) {
        final m = Map<String, dynamic>.from(g as Map);
        final label = (m['label'] as String?) ?? '';
        final choices =
            (m['choices'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
        final freeText = (m['free_text'] as String?)?.trim() ?? '';
        final answers = [...choices, if (freeText.isNotEmpty) freeText];
        if (answers.isEmpty) continue;
        parts.add(label.isEmpty ? answers.join(', ') : '$label: ${answers.join(', ')}');
      }
      return parts.isEmpty ? null : parts.join(' • ');
    } catch (_) {
      return null;
    }
  }
}
