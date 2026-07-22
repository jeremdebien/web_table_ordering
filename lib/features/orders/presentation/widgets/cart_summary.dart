import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/cart_bloc.dart';
import '../../../table/presentation/bloc/table_bloc.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/presentation/bloc/menu_bloc.dart';
import 'serving_status_badge.dart';

class CartSummary extends StatelessWidget {
  const CartSummary({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CartBloc, CartState>(
      listener: (context, state) {
        if (state.status == CartStatus.submitted) {
          debugPrint('Order submitted successfully!');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Order submitted successfully!')),
          );
          // Close the bottom sheet after successful submission
          Navigator.of(context).pop();
        } else if (state.status == CartStatus.failure) {
          debugPrint('Failed to submit order: ${state.errorMessage}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to submit order: ${state.errorMessage}'),
            ),
          );
        }
      },
      builder: (context, state) {
        final cartItems = state.items;
        final subtotal =
            state.activeOrderTotalAmount +
            state.pendingOrderTotalAmount +
            state.newOrderTotalAmount;
        final serviceCharge = subtotal * 0.10;
        final total = subtotal + serviceCharge;
        final totalCount =
            state.activeOrderCount +
            state.pendingOrdersCount +
            state.newOrdersCount;

        final menuState = context.read<MenuBloc>().state;
        List<ItemModel> menuItems = [];
        if (menuState is MenuLoaded) {
          menuItems = menuState.items;
        }

        String? getDisplayImage(String barcode) {
          if (menuItems.isEmpty) return null;
          try {
            final item = menuItems.firstWhere(
              (element) => element.barcode == barcode,
            );
            return item.displayImage;
          } catch (e) {
            return null;
          }
        }

        return Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
            color: Colors.white, // Light beige background
          ),
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Your Order',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A1A),
                      fontFamily: 'PTSerif',
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Color(0xFF1A1A1A),
                      size: 24,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Items count and Clear all
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$totalCount items',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(color: Colors.black12, height: 1),
              const SizedBox(height: 12),
              // Scrollable Order Items List
              Expanded(
                child: cartItems.isEmpty
                    ? const Center(
                        child: Text(
                          'Your cart is empty',
                          style: TextStyle(color: Colors.black54, fontSize: 16),
                        ),
                      )
                    : ListView.separated(
                        itemCount: cartItems.length,
                        separatorBuilder: (context, index) => const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Divider(color: Colors.black12, height: 1),
                        ),
                        itemBuilder: (context, index) {
                          final item = cartItems[index];
                          final displayImage = getDisplayImage(
                            item.itemBarcode,
                          );

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Food Image with Golden Border
                              Container(
                                width: 70,
                                height: 70,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(
                                      0xFFC5A880,
                                    ).withValues(alpha: 0.4),
                                    width: 1.5,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child:
                                      displayImage != null &&
                                          displayImage.isNotEmpty
                                      ? Image.network(
                                          displayImage,
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) =>
                                                  Container(
                                                    color: Colors.grey.shade200,
                                                    child: const Icon(
                                                      Icons.restaurant,
                                                      color: Colors.grey,
                                                      size: 30,
                                                    ),
                                                  ),
                                        )
                                      : Container(
                                          color: Colors.grey.shade200,
                                          child: const Icon(
                                            Icons.restaurant,
                                            color: Colors.grey,
                                            size: 30,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              // Item name, single price and quantity selector row
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      item.itemName.isEmpty
                                                          ? 'Unknown Item'
                                                          : item.itemName,
                                                      style: const TextStyle(
                                                        color: Color(
                                                          0xFF1A1A1A,
                                                        ),
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  if (item.originalQuantity ==
                                                      0) ...[
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 6,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color:
                                                            const Color.fromARGB(
                                                              255,
                                                              235,
                                                              209,
                                                              16,
                                                            ).withValues(
                                                              alpha: 0.15,
                                                            ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              6,
                                                            ),
                                                        border: Border.all(
                                                          color:
                                                              const Color.fromARGB(
                                                                255,
                                                                235,
                                                                209,
                                                                16,
                                                              ),
                                                          width: 0.8,
                                                        ),
                                                      ),
                                                      child: const Text(
                                                        'Additional Order',
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Colors.black87,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                  ],
                                                  // Kitchen serving state, live
                                                  // as staff scan each ticket.
                                                  // Renders nothing for lines
                                                  // not yet submitted.
                                                  if (item
                                                      .hasServingStatus) ...[
                                                    const SizedBox(width: 8),
                                                    ServingStatusBadge(
                                                      item: item,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '₱${item.amount.toStringAsFixed(0)}',
                                                style: TextStyle(
                                                  color: Colors.grey.shade700,
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (item.nickname.isNotEmpty)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFF8A6D4B,
                                              ).withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                color: const Color(
                                                  0xFF8A6D4B,
                                                ).withValues(alpha: 0.3),
                                                width: 1,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.person_outline,
                                                  size: 12,
                                                  color: Color(0xFF8A6D4B),
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  item.nickname,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Color(0xFF8A6D4B),
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),

                                    Row(
                                      children: [
                                        // Minus Button
                                        GestureDetector(
                                          onTap: item.originalQuantity > 0
                                              ? null
                                              : () {
                                                  if (item.quantity > 1) {
                                                    context
                                                        .read<CartBloc>()
                                                        .add(
                                                          AddToCart(
                                                            item.copyWith(
                                                              quantity: -1,
                                                            ),
                                                          ),
                                                        );
                                                  }
                                                },
                                          child: Container(
                                            width: 28,
                                            height: 28,
                                            decoration: const BoxDecoration(
                                              color: Color(0xFF1A1A1A),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.remove,
                                              color: Colors.white,
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          '${item.quantity}',
                                          style: const TextStyle(
                                            color: Color(0xFF1A1A1A),
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Plus Button
                                        GestureDetector(
                                          onTap: item.originalQuantity > 0
                                              ? null
                                              : () {
                                                  context.read<CartBloc>().add(
                                                    AddToCart(
                                                      item.copyWith(
                                                        quantity: 1,
                                                      ),
                                                    ),
                                                  );
                                                },
                                          child: Container(
                                            width: 28,
                                            height: 28,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.grey.shade700,
                                                width: 1,
                                              ),
                                            ),
                                            child: const Icon(
                                              Icons.add,
                                              color: Color(0xFF1A1A1A),
                                              size: 16,
                                            ),
                                          ),
                                        ),
                                        const Spacer(),
                                        // Item total price
                                        Text(
                                          '₱${(item.amount * item.quantity).toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            color: Color(0xFF1A1A1A),
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        // Trash button (delete)
                                        if (item.originalQuantity == 0)
                                          GestureDetector(
                                            onTap: () {
                                              context.read<CartBloc>().add(
                                                RemoveFromCart(item),
                                              );
                                            },
                                            child: Icon(
                                              Icons.delete_outline,
                                              color: Colors.grey.shade700,
                                              size: 20,
                                            ),
                                          )
                                        else
                                          const SizedBox(width: 20),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.black12, height: 1),
              const SizedBox(height: 12),
              // Summary Calculation Section
              Column(
                children: [
                  _buildSummaryRow(
                    'Subtotal',
                    '₱${subtotal.toStringAsFixed(2)}',
                  ),
                  const SizedBox(height: 8),
                  _buildSummaryRow(
                    'Service Charge (10%)',
                    '₱${serviceCharge.toStringAsFixed(2)}',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total',
                        style: TextStyle(
                          color: Color(0xFF1A1A1A),
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '₱${total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Color(0xFF1A1A1A),
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Checkout Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.black12,
                    disabledForegroundColor: Colors.black26,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  onPressed: state.newOrders.isEmpty
                      ? null
                      : () {
                          final tableState = context.read<TableBloc>().state;
                          if (tableState is TableLoaded) {
                            showDialog(
                              context: context,
                              builder: (BuildContext dialogContext) {
                                return AlertDialog(
                                  backgroundColor: const Color(0xFFFAF7F2),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  title: const Text(
                                    'Confirm Order',
                                    style: TextStyle(color: Color(0xFF1A1A1A)),
                                  ),
                                  content: const Text(
                                    'Are you sure you want to place this order?',
                                    style: TextStyle(color: Colors.black54),
                                  ),
                                  actions: <Widget>[
                                    TextButton(
                                      child: const Text(
                                        'Cancel',
                                        style: TextStyle(color: Colors.grey),
                                      ),
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                      },
                                    ),
                                    TextButton(
                                      style: TextButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF8A6D4B,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                      child: const Text(
                                        'Confirm',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
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
                              const SnackBar(
                                content: Text('Table info not available'),
                              ),
                            );
                          }
                        },
                  child: state.status == CartStatus.loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              state.newOrders.isEmpty
                                  ? 'No Orders'
                                  : 'Proceed to Checkout',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.arrow_forward, size: 20),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade700,
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: Colors.grey.shade800,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
