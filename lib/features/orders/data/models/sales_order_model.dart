import 'sales_order_item_model.dart';

class SalesOrderModel {
  final int? id;
  final int tableId;
  final int guestCount;
  final int eligibleGuestCount;
  final int orderType;
  final int paymentStatus;
  final int? appliedDiscountId;
  final bool isSplitBill;
  final bool isCombine;
  final int? paymentDepositId;
  final int? parentSalesOrderId;
  final DateTime? createdAt;
  final DateTime? postingDate;
  final List<SalesOrderItemModel> items;

  SalesOrderModel({
    this.id,
    required this.tableId,
    required this.guestCount,
    this.eligibleGuestCount = 0,
    required this.orderType,
    this.paymentStatus = 0,
    this.appliedDiscountId,
    this.isSplitBill = false,
    this.isCombine = false,
    this.paymentDepositId,
    this.parentSalesOrderId,
    this.createdAt,
    this.postingDate,
    this.items = const [],
  });

  factory SalesOrderModel.fromJson(Map<String, dynamic> json) {
    return SalesOrderModel(
      id: json['sales_order_id'] as int?,
      tableId: json['table_id'] as int,
      guestCount: json['guest_count'] as int,
      eligibleGuestCount: json['eligible_guest_count'] as int? ?? 0,
      orderType: json['order_type'] as int,
      paymentStatus: json['payment_status'] as int? ?? 0,
      appliedDiscountId: json['applied_discount_id'] as int?,
      isSplitBill: (json['is_split_bill'] as int? ?? 0) == 1,
      isCombine: (json['is_combine'] as int? ?? 0) == 1 || (json['is_combine'] as bool? ?? false),
      paymentDepositId: json['payment_deposit_id'] as int?,
      parentSalesOrderId: json['parent_sales_order_id'] as int?,
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at'] as String) : null,
      postingDate: json['posting_date'] != null ? DateTime.parse(json['posting_date'] as String) : null,
      items:
          (json['sales_order_items'] as List<dynamic>?)
              ?.map((e) => SalesOrderItemModel.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'sales_order_id': id,
      'table_id': tableId,
      'guest_count': guestCount,
      'eligible_guest_count': eligibleGuestCount,
      'order_type': orderType,
      'payment_status': paymentStatus,
      'applied_discount_id': appliedDiscountId,
      'is_split_bill': isSplitBill ? 1 : 0,
      'is_combine': isCombine ? 1 : 0,
      'payment_deposit_id': paymentDepositId,
      'parent_sales_order_id': parentSalesOrderId,
      'created_at': createdAt?.toIso8601String(),
      'posting_date': postingDate?.toIso8601String(),
      'sales_order_items': items.map((e) => e.toJson()).toList(),
    };
  }

  SalesOrderModel copyWith({
    int? id,
    int? tableId,
    int? guestCount,
    int? eligibleGuestCount,
    int? orderType,
    int? paymentStatus,
    int? appliedDiscountId,
    bool? isSplitBill,
    bool? isCombine,
    int? paymentDepositId,
    int? parentSalesOrderId,
    DateTime? createdAt,
    DateTime? postingDate,
    List<SalesOrderItemModel>? items,
  }) {
    return SalesOrderModel(
      id: id ?? this.id,
      tableId: tableId ?? this.tableId,
      guestCount: guestCount ?? this.guestCount,
      eligibleGuestCount: eligibleGuestCount ?? this.eligibleGuestCount,
      orderType: orderType ?? this.orderType,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      appliedDiscountId: appliedDiscountId ?? this.appliedDiscountId,
      isSplitBill: isSplitBill ?? this.isSplitBill,
      isCombine: isCombine ?? this.isCombine,
      paymentDepositId: paymentDepositId ?? this.paymentDepositId,
      parentSalesOrderId: parentSalesOrderId ?? this.parentSalesOrderId,
      createdAt: createdAt ?? this.createdAt,
      postingDate: postingDate ?? this.postingDate,
      items: items ?? this.items,
    );
  }
}
