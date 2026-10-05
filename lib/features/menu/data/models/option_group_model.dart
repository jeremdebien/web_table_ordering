/// Product customization catalog (POS consolidator migration 0082), read-only on
/// the web. An option group ("Size", "Add-ons") assigned to a product, with its
/// [values]. Mirrors kwikpos_lite `OptionGroup` / `OptionValue`.
///
/// Values are real catalog items: picking one adds its barcode to the line's
/// `customization` JSON at [OptionValue.priceDelta]. A [isVariant] group is
/// different — picking a value swaps the whole line to that item (its own
/// barcode and price) and the pick is NOT written to `customization`.
class OptionGroup {
  final int id;
  final String name;
  final bool isRequired;

  /// 0 = single, 1 = multiple, 2 = multipleRepeated (same value picked N times).
  final int selectionType;
  final int minSelect;

  /// null = unlimited.
  final int? maxSelect;
  final bool isVariant;
  final bool showCurrentItemAsDefault;
  final String? defaultVariantAlias;
  final List<OptionValue> values;

  const OptionGroup({
    required this.id,
    required this.name,
    this.isRequired = false,
    this.selectionType = 0,
    this.minSelect = 0,
    this.maxSelect,
    this.isVariant = false,
    this.showCurrentItemAsDefault = false,
    this.defaultVariantAlias,
    this.values = const [],
  });

  bool get isSingle => isVariant || selectionType == 0 || maxSelect == 1;
  bool get allowsRepeat => !isSingle && selectionType == 2;

  /// Minimum picks a valid line needs: at least 1 when required, never below
  /// the configured min. Variant groups always resolve to one size.
  int get effectiveMin {
    if (isVariant) return 1;
    final m = minSelect;
    if (isRequired) return m < 1 ? 1 : m;
    return m;
  }

  /// null = no cap. A max of 0 (or unset) on a multiple group means unlimited.
  int? get effectiveMax {
    if (isSingle) return 1;
    final m = maxSelect;
    return (m == null || m <= 0) ? null : m;
  }

  static bool _flag(dynamic v) => v == 1 || v == true || v == '1';

  factory OptionGroup.fromJson(Map<String, dynamic> json, {List<OptionValue> values = const []}) {
    return OptionGroup(
      id: (json['id'] as num).toInt(),
      name: (json['name'] as String?) ?? '',
      isRequired: _flag(json['is_required']),
      selectionType: (json['selection_type'] as num?)?.toInt() ?? 0,
      minSelect: (json['min_select'] as num?)?.toInt() ?? 0,
      maxSelect: (json['max_select'] as num?)?.toInt(),
      isVariant: _flag(json['is_variant']),
      showCurrentItemAsDefault: _flag(json['show_current_item_as_default']),
      defaultVariantAlias: json['default_variant_alias'] as String?,
      values: values,
    );
  }

  OptionGroup copyWith({List<OptionValue>? values}) => OptionGroup(
        id: id,
        name: name,
        isRequired: isRequired,
        selectionType: selectionType,
        minSelect: minSelect,
        maxSelect: maxSelect,
        isVariant: isVariant,
        showCurrentItemAsDefault: showCurrentItemAsDefault,
        defaultVariantAlias: defaultVariantAlias,
        values: values ?? this.values,
      );
}

/// One pickable option. [itemName]/[receiptName] come from the `item` row the
/// value's [barcode] points at; [itemPrice] is that item's own price (used for
/// variant/size values, which replace the line's price).
class OptionValue {
  final int id;
  final String barcode;
  final String? alias;
  /// null = no override: the pick costs the value item's own price (POS
  /// `CompleteOptionValue.effectivePriceDelta`).
  final double? priceDelta;
  final double quantity;
  final int unit;
  final int displayOrder;
  final String itemName;
  final String? receiptName;
  final double itemPrice;

  /// Public URL of the value item's image (master-file bucket), if any.
  final String? imageUrl;

  /// Per-size overrides of [priceDelta]/[alias], keyed by the size barcode the
  /// line resolves to (product_option_value_overrides). Lets "Oat milk" cost
  /// more on a Large than a Small.
  final Map<String, ({double? priceDelta, String? alias})> overridesByProduct;

  const OptionValue({
    required this.id,
    required this.barcode,
    this.alias,
    this.priceDelta,
    this.quantity = 1,
    this.unit = 1,
    this.displayOrder = 0,
    required this.itemName,
    this.receiptName,
    this.itemPrice = 0,
    this.imageUrl,
    this.overridesByProduct = const {},
  });

  /// Alias-else-item-name, matching how the POS names customization lines.
  /// [productBarcode] is the line's resolved (size) barcode; [baseBarcode] the
  /// product the groups are assigned to — its overrides apply as a fallback.
  String labelFor(String productBarcode, [String? baseBarcode]) {
    final a = overridesByProduct[productBarcode]?.alias ??
        (baseBarcode != null ? overridesByProduct[baseBarcode]?.alias : null) ??
        alias;
    return (a != null && a.trim().isNotEmpty) ? a : itemName;
  }

  double priceFor(String productBarcode, [String? baseBarcode]) =>
      overridesByProduct[productBarcode]?.priceDelta ??
      (baseBarcode != null ? overridesByProduct[baseBarcode]?.priceDelta : null) ??
      priceDelta ??
      itemPrice;
}
