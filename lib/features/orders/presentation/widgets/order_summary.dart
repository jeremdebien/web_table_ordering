import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/cart_bloc.dart';
import '../../../table/presentation/bloc/table_bloc.dart';
import 'order_list.dart';

class OrderSummary extends StatelessWidget {
  final bool isViewOnly;

  const OrderSummary({
    super.key,
    this.isViewOnly = false,
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
        return Container(
          padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Colors.white,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              const Text(
                'Order Summary',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const Divider(),
              OrderList(items: state.items),
              // Calculate total quantity and VAT
              Builder(
                builder: (context) {
                  final totalQuantity = state.items.fold<int>(
                    0,
                    (sum, item) => sum + item.quantity,
                  );
                  final subtotal = state.totalAmount;
                  final vat = subtotal * 0.12;
                  final totalWithVat = subtotal;

                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.black,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        children: [
                          // Total Quantity
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total Quantity:',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '$totalQuantity',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'VAT (12%):',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '₱${vat.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Divider(),
                          // Total with VAT
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total:',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '₱${totalWithVat.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              if (!isViewOnly) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFff25125),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
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
                                    backgroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    title: const Text('Confirm Order'),
                                    content: const Text(
                                      'Are you sure you want to place this order?',
                                    ),
                                    actions: <Widget>[
                                      TextButton(
                                        child: const Text('Cancel'),
                                        onPressed: () {
                                          Navigator.of(dialogContext).pop();
                                        },
                                      ),
                                      TextButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFFff25125,
                                          ),
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
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
                                const SnackBar(
                                  content: Text('Table info not available'),
                                ),
                              );
                            }
                          },
                    child: state.status == CartStatus.loading
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text('Sending...'),
                            ],
                          )
                        : Text(
                            state.newOrders.isEmpty
                                ? 'No Orders'
                                : 'Place Order',
                          ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
