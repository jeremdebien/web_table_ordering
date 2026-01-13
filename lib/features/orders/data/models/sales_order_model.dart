import 'sales_order_item_model.dart';

class SalesOrderModel {
  final int? id; // Nullable for new orders
  final DateTime? createdAt;
  final String status;
  final double totalAmount;
  final String? tableUuid;
  final List<SalesOrderItemModel> items;

  SalesOrderModel({
    this.id,
    this.createdAt,
    this.status = 'pending',
    required this.totalAmount,
    this.tableUuid,
    required this.items,
  });

  factory SalesOrderModel.fromJson(Map<String, dynamic> json) {
    return SalesOrderModel(
      id: json['id'] as int?,
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at'] as String) : null,
      status: json['status'] as String? ?? 'pending',
      totalAmount: (json['total_amount'] as num).toDouble(),
      tableUuid: json['table_uuid'] as String?,
      items:
          (json['sales_order_items'] as List<dynamic>?)
              ?.map((e) => SalesOrderItemModel.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'status': status,
      'total_amount': totalAmount,
      'table_uuid': tableUuid,
      // created_at is usually handled by DB default
      'items': items.map((e) => e.toJson()).toList(),
    };
  }
}
