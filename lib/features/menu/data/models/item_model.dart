import '../../../../core/config/app_config.dart';

class ItemModel {
  final int id;
  final String barcode;
  final String itemCode;
  final String name;
  final String? description;
  final bool isAvailable;

  /// Whether the item is shown on the customer-facing web ordering menu.
  /// Web-only (consolidator column `is_available_in_web_table`, migration 0046);
  /// independent of `isAvailable`/`item_status`. Defaults to visible.
  final bool isAvailableInWebTable;
  final String? printDesc;
  final int departmentId;
  final int categoryId;
  final double? costPrice;
  final double? markUp;
  final double price;
  final double? price1;
  final double? price2;
  final double? price3;
  final double? price4;
  final double? price5;
  final String? assignedPrinter;
  final bool isDiscExempt;
  final bool isNonVat;
  final String? _displayImage;
  final int? buttonIndex;
  final DateTime createdAt;
  final DateTime? updatedAt;

  String? get displayImage {
    if (_displayImage == null || _displayImage.isEmpty) return null;
    return '${AppConfig.imageStoragePath}$_displayImage';
  }

  ItemModel({
    required this.id,
    required this.barcode,
    required this.itemCode,
    required this.name,
    this.description,
    this.isAvailable = false,
    this.isAvailableInWebTable = true,
    this.printDesc,
    required this.departmentId,
    required this.categoryId,
    this.costPrice,
    this.markUp,
    required this.price,
    this.price1,
    this.price2,
    this.price3,
    this.price4,
    this.price5,
    this.assignedPrinter,
    this.isDiscExempt = false,
    this.isNonVat = false,
    String? displayImage,
    this.buttonIndex,
    required this.createdAt,
    this.updatedAt,
  }) : _displayImage = displayImage;

  factory ItemModel.fromJson(Map<String, dynamic> json) {
    return ItemModel(
      id: json['id'] as int,
      barcode: json['barcode'] as String,
      itemCode: json['item_code'] as String,
      name: json['item_name'] as String,
      description: json['item_desc'] as String?,
      isAvailable: (json['item_status'] as int?) == 1,
      // Missing/null => visible (default 1). Only an explicit 0 hides it.
      isAvailableInWebTable: (json['is_available_in_web_table'] as int?) != 0,
      printDesc: json['print_desc'] as String?,
      departmentId: json['department_id'] as int,
      categoryId: json['category_id'] as int,
      costPrice: (json['cost_price'] as num?)?.toDouble(),
      markUp: (json['mark_up'] as num?)?.toDouble(),
      price: (json['price'] as num).toDouble(),
      price1: (json['price_1'] as num?)?.toDouble(),
      price2: (json['price_2'] as num?)?.toDouble(),
      price3: (json['price_3'] as num?)?.toDouble(),
      price4: (json['price_4'] as num?)?.toDouble(),
      price5: (json['price_5'] as num?)?.toDouble(),
      assignedPrinter: json['assigned_printer'] as String?,
      isDiscExempt: json['is_disc_exempt'] as bool? ?? false,
      isNonVat: json['is_non_vat'] as bool? ?? false,
      displayImage: json['display_image'] as String?,
      buttonIndex: json['button_index'] as int?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['update_at'] != null ? DateTime.parse(json['update_at'] as String) : null,
    );
  }

  ItemModel copyWith({
    bool? isAvailable,
    bool? isAvailableInWebTable,
    int? buttonIndex,
  }) {
    return ItemModel(
      id: id,
      barcode: barcode,
      itemCode: itemCode,
      name: name,
      description: description,
      isAvailable: isAvailable ?? this.isAvailable,
      isAvailableInWebTable: isAvailableInWebTable ?? this.isAvailableInWebTable,
      printDesc: printDesc,
      departmentId: departmentId,
      categoryId: categoryId,
      costPrice: costPrice,
      markUp: markUp,
      price: price,
      price1: price1,
      price2: price2,
      price3: price3,
      price4: price4,
      price5: price5,
      assignedPrinter: assignedPrinter,
      isDiscExempt: isDiscExempt,
      isNonVat: isNonVat,
      displayImage: _displayImage,
      buttonIndex: buttonIndex ?? this.buttonIndex,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'barcode': barcode,
      'item_code': itemCode,
      'item_name': name,
      'item_desc': description,
      'item_status': isAvailable ? 1 : 0,
      'is_available_in_web_table': isAvailableInWebTable ? 1 : 0,
      'print_desc': printDesc,
      'department_id': departmentId,
      'category_id': categoryId,
      'cost_price': costPrice,
      'mark_up': markUp,
      'price': price,
      'price_1': price1,
      'price_2': price2,
      'price_3': price3,
      'price_4': price4,
      'price_5': price5,
      'assigned_printer': assignedPrinter,
      'is_disc_exempt': isDiscExempt,
      'is_non_vat': isNonVat,
      'display_image': _displayImage,
      'button_index': buttonIndex,
      'created_at': createdAt.toIso8601String(),
      'update_at': updatedAt?.toIso8601String(),
    };
  }
}
