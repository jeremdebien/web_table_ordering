class SalesOrderItemModel {
  final int? id;
  final int? orderItemId;
  final int? salesOrderId;
  final String itemBarcode;
  final String itemName; // Added for UI display
  final int quantity;
  final double amount;
  final String? itemModifiers;
  final bool isDiscExempt;
  final double? itemDiscount;
  final DateTime? postingDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int originalQuantity; // Added to distinguish new vs existing items
  final String status; // Added to distinguish pending vs accepted items
  final String nickname; // Added for customer tracking
  final String? webDeviceId; // Stable ordering-device id (web app); nullable for POS/legacy rows
  final String? specialInstructions; // JSON: answers to per-item instruction questions

  /// Kitchen serving state of the line: 'preparing' or 'served'. Distinct from
  /// [status], which tracks pending/accepted/cancelled submission. Derived on
  /// the consolidator from [servedQuantity] vs [quantity]
  /// (`sales_order_item.item_status`); null in online mode, which has no such
  /// column. Read-only — the app never writes it. Prefer [isServed] for display.
  final String? servingStatus;

  /// How much of the line has been served so far. Each printed ticket covers
  /// only the quantity it was printed for, so a line can be partly served
  /// (e.g. 2 of 3). Read-only, see [servingStatus].
  final double servedQuantity;

  /// True once the whole line has been served.
  ///
  /// Derived from the quantities rather than [servingStatus] so it stays correct
  /// the moment a served line grows — re-ordering the same item merges into the
  /// existing line, turning a fully-served "3x A" into "4x A", and the stored
  /// status would still read 'served' until the new ticket is scanned.
  bool get isServed => quantity > 0 && servedQuantity >= quantity;

  /// True when some — but not all — of the line has been served.
  bool get isPartiallyServed => !isServed && servedQuantity > 0;

  /// Whether this line has serving information to show at all. False for lines
  /// not yet submitted, and in online mode.
  bool get hasServingStatus => servingStatus != null && originalQuantity > 0;

  // Amount is now the Unit Price
  double get unitPrice => amount;

  // Total Price for display = Unit Price * Quantity
  double get totalPrice => amount * quantity;

  SalesOrderItemModel({
    this.id,
    this.orderItemId,
    this.salesOrderId,
    required this.itemBarcode,
    this.itemName = '', // Default empty if not available
    required this.quantity,
    required this.amount,
    this.itemModifiers,
    this.isDiscExempt = false,
    this.itemDiscount,
    this.postingDate,
    this.createdAt,
    this.updatedAt,
    this.originalQuantity = 0,
    this.status = 'Accepted',
    this.nickname = '',
    this.webDeviceId,
    this.specialInstructions,
    this.servingStatus,
    this.servedQuantity = 0,
  });

  factory SalesOrderItemModel.fromJson(Map<String, dynamic> json) {
    final qty = json['quantity'] as int;

    bool toBool(dynamic value) {
      if (value is bool) return value;
      if (value is int) return value == 1;
      return false;
    }

    return SalesOrderItemModel(
      id: json['id'] as int?,
      orderItemId: json['order_item_id'] as int?,
      salesOrderId: json['sales_order_id'] as int?,
      itemBarcode: json['item_barcode'] as String,
      quantity: qty,
      amount: (json['amount'] as num).toDouble(),
      itemModifiers: json['item_modifiers'] as String?,
      isDiscExempt: toBool(json['is_disc_exempt']),
      itemDiscount: (json['item_discount'] as num?)?.toDouble(),
      postingDate: json['posting_date'] != null ? DateTime.parse(json['posting_date'] as String) : null,
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at'] as String) : null,
      updatedAt: json['updated_at'] != null ? DateTime.parse(json['updated_at'] as String) : null,
      originalQuantity: qty, // Set originalQuantity to quantity for DB items
      status: json['status'] as String? ?? 'Accepted',
      nickname: json['nickname'] as String? ?? json['customer_name'] as String? ?? '',
      webDeviceId: json['web_device_id'] as String?,
      specialInstructions: json['special_instructions'] as String?,
      // Present only in local (consolidator) mode; absent online.
      servingStatus: json['item_status'] as String?,
      servedQuantity: (json['served_quantity'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      if (orderItemId != null) 'order_item_id': orderItemId,
      if (salesOrderId != null) 'sales_order_id': salesOrderId,
      'item_barcode': itemBarcode,
      'quantity': quantity,
      'amount': amount,
      'item_modifiers': itemModifiers,
      'is_disc_exempt': isDiscExempt ? 1 : 0,
      'item_discount': itemDiscount,
      'posting_date': postingDate?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'status': status,
      'nickname': nickname,
      'customer_name': nickname,
      if (webDeviceId != null) 'web_device_id': webDeviceId,
      'special_instructions': specialInstructions,
    };
  }

  SalesOrderItemModel copyWith({
    int? id,
    int? orderItemId,
    int? salesOrderId,
    String? itemBarcode,
    String? itemName,
    int? quantity,
    double? amount,
    String? itemModifiers,
    bool? isDiscExempt,
    double? itemDiscount,
    DateTime? postingDate,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? originalQuantity,
    String? status,
    String? nickname,
    String? webDeviceId,
    String? specialInstructions,
    String? servingStatus,
    double? servedQuantity,
  }) {
    return SalesOrderItemModel(
      id: id ?? this.id,
      orderItemId: orderItemId ?? this.orderItemId,
      salesOrderId: salesOrderId ?? this.salesOrderId,
      itemBarcode: itemBarcode ?? this.itemBarcode,
      itemName: itemName ?? this.itemName,
      quantity: quantity ?? this.quantity,
      amount: amount ?? this.amount,
      itemModifiers: itemModifiers ?? this.itemModifiers,
      isDiscExempt: isDiscExempt ?? this.isDiscExempt,
      itemDiscount: itemDiscount ?? this.itemDiscount,
      postingDate: postingDate ?? this.postingDate,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      originalQuantity: originalQuantity ?? this.originalQuantity,
      status: status ?? this.status,
      nickname: nickname ?? this.nickname,
      webDeviceId: webDeviceId ?? this.webDeviceId,
      specialInstructions: specialInstructions ?? this.specialInstructions,
      servingStatus: servingStatus ?? this.servingStatus,
      servedQuantity: servedQuantity ?? this.servedQuantity,
    );
  }
}
