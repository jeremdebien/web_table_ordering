import 'package:flutter/material.dart';
import '../../data/models/sales_order_item_model.dart';

/// "Preparing" / "Served 2/3" / "Served" chip, mirroring the badge the POS
/// sales-order screen shows for the same line.
///
/// Driven by `sales_order_item.item_status` / `served_quantity`, which the
/// kitchen's ticket scanner advances — each printed ticket covers only the
/// quantity it was printed for, so a line can sit part-served. Renders nothing
/// unless the line actually has serving info ([SalesOrderItemModel.hasServingStatus]):
/// items not yet submitted have none, and neither does online mode, whose schema
/// has no such column.
class ServingStatusBadge extends StatelessWidget {
  final SalesOrderItemModel item;

  const ServingStatusBadge({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    if (!item.hasServingStatus) return const SizedBox.shrink();

    final served = item.isServed;
    final label = served
        ? 'Served'
        : item.isPartiallyServed
            ? 'Served ${_qty(item.servedQuantity)}/${item.quantity}'
            : 'Preparing';
    final color = served ? Colors.green : Colors.orange;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            served ? Icons.check_circle : Icons.access_time,
            size: 11,
            color: color.shade800,
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color.shade800,
            ),
          ),
        ],
      ),
    );
  }

  /// Drop the trailing ".0" so a whole number reads "2", not "2.0".
  String _qty(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();
}
