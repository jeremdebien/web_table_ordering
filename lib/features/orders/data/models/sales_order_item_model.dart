class SalesOrderItemModel {
  final int? id;
  final int? salesOrderId;
  final int itemId;
  final int quantity;
  final double unitPrice;
  final double subtotal;
  final String? notes;

  SalesOrderItemModel({
    this.id,
    this.salesOrderId,
    required this.itemId,
    required this.quantity,
    required this.unitPrice,
    required this.subtotal,
    this.notes,
  });

  factory SalesOrderItemModel.fromJson(Map<String, dynamic> json) {
    return SalesOrderItemModel(
      id: json['id'] as int?,
      salesOrderId: json['sales_order_id'] as int?,
      itemId: json['item_id'] as int,
      quantity: json['quantity'] as int,
      unitPrice: (json['unit_price'] as num).toDouble(),
      subtotal: (json['subtotal'] as num).toDouble(),
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      if (salesOrderId != null) 'sales_order_id': salesOrderId,
      'item_id': itemId,
      'quantity': quantity,
      'unit_price': unitPrice,
      'subtotal': subtotal,
      'notes': notes,
    };
  }
}
