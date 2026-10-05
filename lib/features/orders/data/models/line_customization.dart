import 'dart:convert';

/// One picked option on an order line, in the POS `ProductOrder.toJson` shape
/// that `sales_order_item.customization` stores:
/// `{ "<groupName>": [ {productBarcode, productName, receiptName, price, quantity, conversionQty, unit}, ... ] }`.
///
/// [price] is the per-unit price delta; [quantity] is how many times the option
/// was picked for ONE unit of the item. The line's unit price already includes
/// Σ price × quantity (never add it twice).
class CustomizationPick {
  final String productBarcode;
  final String productName;
  final String? receiptName;
  final double price;
  final int quantity;
  final double conversionQty;
  final int unit;

  const CustomizationPick({
    required this.productBarcode,
    required this.productName,
    this.receiptName,
    this.price = 0,
    this.quantity = 1,
    this.conversionQty = 1,
    this.unit = 1,
  });

  Map<String, dynamic> toJson() => {
        'productBarcode': productBarcode,
        // Older KDS builds parse `barcode`; keep both.
        'barcode': productBarcode,
        'productName': productName,
        'receiptName': receiptName ?? productName,
        'price': price,
        'quantity': quantity,
        'conversionQty': conversionQty,
        'unit': unit,
      };

  factory CustomizationPick.fromJson(Map<String, dynamic> json) => CustomizationPick(
        productBarcode: (json['productBarcode'] ?? json['barcode'] ?? '').toString(),
        productName: (json['productName'] ?? json['receiptName'] ?? '').toString(),
        receiptName: json['receiptName'] as String?,
        price: (json['price'] as num?)?.toDouble() ?? 0,
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        conversionQty: (json['conversionQty'] as num?)?.toDouble() ?? 1,
        unit: (json['unit'] as num?)?.toInt() ?? 1,
      );
}

/// Helpers over the `customization` TEXT JSON (group name → picks).
class LineCustomization {
  LineCustomization._();

  static String? encode(Map<String, List<CustomizationPick>> picks) {
    final nonEmpty = {
      for (final e in picks.entries)
        if (e.value.isNotEmpty) e.key: e.value.map((p) => p.toJson()).toList(),
    };
    return nonEmpty.isEmpty ? null : jsonEncode(nonEmpty);
  }

  static Map<String, List<CustomizationPick>> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, List<CustomizationPick>>{};
      decoded.forEach((group, list) {
        if (list is! List) return;
        final picks = list
            .whereType<Map>()
            .map((m) => CustomizationPick.fromJson(Map<String, dynamic>.from(m)))
            .toList();
        if (picks.isNotEmpty) out[group.toString()] = picks;
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Σ price × quantity for one unit of the item.
  static double unitDelta(Map<String, List<CustomizationPick>> picks) =>
      picks.values.expand((l) => l).fold(0.0, (sum, p) => sum + p.price * p.quantity);

  /// Order-independent identity (port of POS `CustomizationHelper.fingerprint`):
  /// same barcode + same fingerprint may merge into one line. '' when none.
  static String fingerprint(String? raw) {
    final picks = decode(raw);
    if (picks.isEmpty) return '';
    final parts = <String>[
      for (final e in picks.entries)
        for (final p in e.value) '${e.key}:${p.productBarcode}:${p.quantity}:${p.price.toStringAsFixed(2)}',
    ]..sort();
    return parts.join('|');
  }

  /// Display lines, e.g. "Add-ons: 2x Egg (+₱40), Nori".
  static List<String> displayLines(String? raw) {
    final picks = decode(raw);
    return [
      for (final e in picks.entries)
        '${e.key}: ${e.value.map((p) {
          final qty = p.quantity > 1 ? '${p.quantity}x ' : '';
          final total = p.price * p.quantity;
          final price = total > 0 ? ' (+₱${_fmt(total)})' : '';
          return '$qty${p.productName}$price';
        }).join(', ')}',
    ];
  }

  static String _fmt(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);
}
