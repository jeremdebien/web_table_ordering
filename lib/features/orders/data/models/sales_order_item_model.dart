class SalesOrderItemModel {
  final int? id;
  final int? salesOrderId;
  final String itemBarcode;
  final String itemName; // Added for UI display
  final int quantity;
  final double amount;
  final String? itemModifiers;
  final bool isDiscExempt;
  final double? itemDiscount;
  final DateTime? postingDate;

  double get unitPrice => quantity > 0 ? amount / quantity : 0;

  SalesOrderItemModel({
    this.id,
    this.salesOrderId,
    required this.itemBarcode,
    this.itemName = '', // Default empty if not available
    required this.quantity,
    required this.amount,
    this.itemModifiers,
    this.isDiscExempt = false,
    this.itemDiscount,
    this.postingDate,
  });

  factory SalesOrderItemModel.fromJson(Map<String, dynamic> json) {
    return SalesOrderItemModel(
      id: json['order_item_id'] as int?,
      salesOrderId: json['sales_order_id'] as int?,
      itemBarcode: json['item_barcode'] as String,
      quantity: json['quantity'] as int,
      amount: (json['amount'] as num).toDouble(),
      itemModifiers: json['item_modifiers'] as String?,
      isDiscExempt: (json['is_disc_exempt'] as int? ?? 0) == 1 || (json['is_disc_exempt'] as bool? ?? false),
      itemDiscount: (json['item_discount'] as num?)?.toDouble(),
      postingDate: json['posting_date'] != null ? DateTime.parse(json['posting_date'] as String) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'order_item_id': id,
      if (salesOrderId != null) 'sales_order_id': salesOrderId,
      'item_barcode': itemBarcode,
      'quantity': quantity,
      'amount': amount,
      'item_modifiers': itemModifiers,
      'is_disc_exempt': isDiscExempt ? 1 : 0,
      'item_discount': itemDiscount,
      'posting_date': postingDate?.toIso8601String(),
    };
  }

  SalesOrderItemModel copyWith({
    int? id,
    int? salesOrderId,
    String? itemBarcode,
    String? itemName,
    int? quantity,
    double? amount,
    String? itemModifiers,
    bool? isDiscExempt,
    double? itemDiscount,
    DateTime? postingDate,
  }) {
    return SalesOrderItemModel(
      id: id ?? this.id,
      salesOrderId: salesOrderId ?? this.salesOrderId,
      itemBarcode: itemBarcode ?? this.itemBarcode,
      itemName: itemName ?? this.itemName,
      quantity: quantity ?? this.quantity,
      amount: amount ?? this.amount,
      itemModifiers: itemModifiers ?? this.itemModifiers,
      isDiscExempt: isDiscExempt ?? this.isDiscExempt,
      itemDiscount: itemDiscount ?? this.itemDiscount,
      postingDate: postingDate ?? this.postingDate,
    );
  }
}
