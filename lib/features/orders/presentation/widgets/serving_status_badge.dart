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
    final partial = item.isPartiallyServed;

    final String label;
    final IconData icon;
    final Color bgColor;
    final Color textColor;
    final Color borderColor;

    if (served) {
      label = 'Served';
      icon = Icons.check_circle_rounded;
      bgColor = const Color(0xFFE8F5E9);
      textColor = const Color(0xFF2E7D32);
      borderColor = const Color(0xFFA5D6A7);
    } else if (partial) {
      label = 'Served ${_qty(item.servedQuantity)}/${item.quantity}';
      icon = Icons.pie_chart_rounded;
      bgColor = const Color(0xFFFFF3E0);
      textColor = const Color(0xFFE65100);
      borderColor = const Color(0xFFFFCC80);
    } else {
      label = 'Preparing';
      icon = Icons.access_time_rounded;
      bgColor = const Color(0xFFFFF8E1);
      textColor = const Color(0xFFF57F17);
      borderColor = const Color(0xFFFFE082);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 11,
            color: textColor,
          ),
          const SizedBox(width: 3.5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: textColor,
              letterSpacing: 0.2,
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
