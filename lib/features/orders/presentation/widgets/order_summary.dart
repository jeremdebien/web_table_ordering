import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/cart_bloc.dart';
import 'order_list.dart';

class OrderSummary extends StatelessWidget {
  const OrderSummary({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CartBloc, CartState>(
      listener: (context, state) {
        // No order submission logic needed in summary view
      },
      builder: (context, state) {
        // Filter items for Order Summary: Active Orders only
        final activeOrderItems = state.activeOrders;

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
              activeOrderItems.isEmpty
                  ? const Expanded(child: Center(child: Text('No active orders')))
                  : OrderList(items: activeOrderItems),
              // Calculate total quantity and VAT
              Builder(
                builder: (context) {
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
                          _buildSummaryRow(
                            'Total Quantity:',
                            '${state.activeOrderCount}',
                          ),
                          if (state.activeOrders.isNotEmpty) ...[
                            _buildSummaryRow(
                              'Orders (${state.activeOrderCount}): ',
                              '₱${state.activeOrderTotalAmount.toStringAsFixed(2)}',
                            ),
                          ],
                          const Divider(),
                          // Total with VAT
                          _buildSummaryRow(
                            'Total:',
                            '₱${state.activeOrderTotalAmount.toStringAsFixed(2)}',
                            isTotal: true,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isTotal = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: isTotal ? 14 : 12,
            fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
            color: Colors.white,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: isTotal ? 14 : 12,
            fontWeight: isTotal ? FontWeight.bold : FontWeight.w500,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
