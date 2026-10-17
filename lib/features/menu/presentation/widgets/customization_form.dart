import 'package:flutter/material.dart';
import '../../data/models/option_group_model.dart';
import '../../../orders/data/models/line_customization.dart';

/// What the guest configured: the line's resolved barcode/name/base price
/// (a size pick swaps them), the option picks, and whether every group is
/// satisfied.
class CustomizationResult {
  final bool isValid;
  final String barcode;
  final String itemName;

  /// Unit price of the resolved item, before option deltas.
  final double basePrice;

  /// Σ option price × count for one unit.
  final double optionsDelta;

  /// `sales_order_item.customization` JSON (null when nothing picked).
  final String? customizationJson;

  /// Base product when a size group resolved the line (POS migration 0083).
  final String? baseVariantBarcode;

  const CustomizationResult({
    required this.isValid,
    required this.barcode,
    required this.itemName,
    required this.basePrice,
    this.optionsDelta = 0,
    this.customizationJson,
    this.baseVariantBarcode,
  });

  double get unitPrice => basePrice + optionsDelta;
}

/// Renders POS product-customization option groups (kwikpos_lite
/// ItemCustomizeDialog, core + size variants): single groups as radios,
/// multiple as checkboxes capped at max, multipleRepeated as steppers.
/// Variant groups come first and swap the line's item/price; add-on prices
/// follow the chosen size (per-product overrides).
class CustomizationForm extends StatefulWidget {
  final List<OptionGroup> groups;
  final String baseBarcode;
  final String baseName;
  final double basePrice;
  final String? baseImageUrl;

  /// Edit flow: the line's current barcode (a size) and customization JSON.
  final String? initialBarcode;
  final String? initialCustomization;
  final void Function(CustomizationResult result) onChanged;

  const CustomizationForm({
    super.key,
    required this.groups,
    required this.baseBarcode,
    required this.baseName,
    required this.basePrice,
    this.baseImageUrl,
    this.initialBarcode,
    this.initialCustomization,
    required this.onChanged,
  });

  @override
  State<CustomizationForm> createState() => _CustomizationFormState();
}

class _CustomizationFormState extends State<CustomizationForm> {
  static const _accent = Color(0xFFC5A880);
  static const _baseValueId = -1;

  // Card text block under the square image: 6 + name slot + 2 + price (~16) + 8,
  // plus a hair of slack so nothing overflows.
  static const double _nameSlot = 32;
  static const double _cardTextBlock = 6 + _nameSlot + 2 + 16 + 8 + 4;

  // group id -> value id -> count
  final Map<int, Map<int, int>> _counts = {};
  late final List<OptionGroup> _groups;

  @override
  void initState() {
    super.initState();
    _groups = widget.groups.map(_withBaseValue).toList();
    _seed();
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  /// A variant group with `show_current_item_as_default` offers the base item
  /// itself as a size (POS seeds it under `default_variant_alias`).
  OptionGroup _withBaseValue(OptionGroup g) {
    if (!g.isVariant || !g.showCurrentItemAsDefault) return g;
    final alias = g.defaultVariantAlias;
    return g.copyWith(values: [
      OptionValue(
        id: _baseValueId,
        barcode: widget.baseBarcode,
        alias: (alias != null && alias.trim().isNotEmpty) ? alias : null,
        itemName: widget.baseName,
        itemPrice: widget.basePrice,
        imageUrl: widget.baseImageUrl,
      ),
      ...g.values.where((v) => v.barcode != widget.baseBarcode),
    ]);
  }

  void _seed() {
    final initial = LineCustomization.decode(widget.initialCustomization);
    for (final g in _groups) {
      final counts = _counts.putIfAbsent(g.id, () => {});
      if (g.isVariant) {
        final match = widget.initialBarcode == null
            ? null
            : g.values.where((v) => v.barcode == widget.initialBarcode).firstOrNull;
        // POS auto-selects the first size so the line always resolves to one.
        final pick = match ?? g.values.first;
        counts[pick.id] = 1;
        continue;
      }
      for (final p in initial[g.name] ?? const <CustomizationPick>[]) {
        final v = g.values.where((v) => v.barcode == p.productBarcode).firstOrNull;
        if (v != null) counts[v.id] = (g.allowsRepeat ? p.quantity : 1);
      }
    }
  }

  OptionValue? get _selectedSize {
    for (final g in _groups.where((g) => g.isVariant)) {
      final id = _counts[g.id]?.keys.firstOrNull;
      if (id != null) return g.values.firstWhere((v) => v.id == id);
    }
    return null;
  }

  String get _currentBarcode => _selectedSize?.barcode ?? widget.baseBarcode;

  int _total(OptionGroup g) => _counts[g.id]?.values.fold<int>(0, (a, b) => a + b) ?? 0;

  bool _satisfied(OptionGroup g) {
    final n = _total(g);
    if (n < g.effectiveMin) return false;
    final max = g.effectiveMax;
    return max == null || n <= max;
  }

  void _emit() {
    final size = _selectedSize;
    final barcode = _currentBarcode;
    final picks = <String, List<CustomizationPick>>{};
    for (final g in _groups.where((g) => !g.isVariant)) {
      final counts = _counts[g.id] ?? const {};
      final list = <CustomizationPick>[
        for (final v in g.values)
          if ((counts[v.id] ?? 0) > 0)
            CustomizationPick(
              productBarcode: v.barcode,
              productName: v.labelFor(barcode, widget.baseBarcode),
              receiptName: v.receiptName,
              price: v.priceFor(barcode, widget.baseBarcode),
              quantity: counts[v.id]!,
              conversionQty: v.quantity,
              unit: v.unit,
            ),
      ];
      if (list.isNotEmpty) picks[g.name] = list;
    }
    widget.onChanged(CustomizationResult(
      isValid: _groups.every(_satisfied),
      barcode: barcode,
      itemName: size == null || size.id == _baseValueId ? widget.baseName : size.itemName,
      basePrice: size == null ? widget.basePrice : size.itemPrice,
      optionsDelta: LineCustomization.unitDelta(picks),
      customizationJson: LineCustomization.encode(picks),
      baseVariantBarcode: size != null ? widget.baseBarcode : null,
    ));
  }

  void _tap(OptionGroup g, OptionValue v) {
    setState(() {
      final counts = _counts.putIfAbsent(g.id, () => {});
      final selected = (counts[v.id] ?? 0) > 0;
      if (g.isSingle) {
        if (selected) {
          // Optional radios can be cleared; sizes and required ones cannot.
          if (!g.isVariant && g.effectiveMin == 0) counts.clear();
        } else {
          counts
            ..clear()
            ..[v.id] = 1;
        }
      } else if (selected && !g.allowsRepeat) {
        counts.remove(v.id);
      } else {
        final max = g.effectiveMax;
        if (max == null || _total(g) < max) counts[v.id] = (counts[v.id] ?? 0) + 1;
      }
    });
    _emit();
  }

  void _decrement(OptionGroup g, OptionValue v) {
    setState(() {
      final counts = _counts[g.id];
      if (counts == null) return;
      final n = (counts[v.id] ?? 0) - 1;
      if (n <= 0) {
        counts.remove(v.id);
      } else {
        counts[v.id] = n;
      }
    });
    _emit();
  }

  String _hint(OptionGroup g) {
    if (g.isVariant) return 'Choose a size';
    if (g.isSingle) return g.effectiveMin > 0 ? 'Select 1 (Required)' : 'Select up to 1 (Optional)';
    final max = g.effectiveMax;
    final maxTxt = max == null ? 'any' : 'up to $max';
    if (g.effectiveMin > 0) return 'Pick ${g.effectiveMin}${max == null ? '+' : '–$max'} (Required)';
    return 'Pick $maxTxt (Optional)';
  }

  static String _fmt(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final barcode = _currentBarcode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in _groups)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _satisfied(g) ? const Color(0xFFE5E7EB) : const Color(0xFFE25822).withValues(alpha: 0.5),
                width: _satisfied(g) ? 1 : 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        g.name,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
                      ),
                    ),
                    if (g.effectiveMin > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE25822).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'REQUIRED',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFE25822)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_hint(g), style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    // ~110px cards: 3 across in the 500px sheet, 2 on narrow phones.
                    // Same rule as the menu grid (menu_page.dart): derive the cell
                    // ratio from the width so the image is a perfect square and
                    // the fixed text block below fits at any width.
                    const double spacing = 10;
                    final cols = (constraints.maxWidth / 110).floor().clamp(2, 4);
                    final itemWidth = (constraints.maxWidth - spacing * (cols - 1)) / cols;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        childAspectRatio: itemWidth / (itemWidth + _cardTextBlock),
                      ),
                      itemCount: g.values.length,
                      itemBuilder: (_, i) => _card(g, g.values[i], barcode),
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _card(OptionGroup g, OptionValue v, String barcode) {
    final count = _counts[g.id]?[v.id] ?? 0;
    final selected = count > 0;
    final String priceText;
    if (g.isVariant) {
      priceText = '₱${_fmt(v.itemPrice)}';
    } else {
      final p = v.priceFor(barcode, widget.baseBarcode);
      priceText = p > 0 ? '+₱${_fmt(p)}' : 'Free';
    }
    final label = g.isVariant ? v.labelFor(v.barcode) : v.labelFor(barcode, widget.baseBarcode);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _tap(g, v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF1A1A1A) : const Color(0xFFE5E7EB),
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Square image, uniform across every card.
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _image(v.imageUrl),
                  // Selection badge: radio/check, or the repeat count.
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: g.allowsRepeat && selected ? 7 : 2, vertical: 2),
                      decoration: BoxDecoration(
                        color: selected ? const Color(0xFF1A1A1A) : Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: g.allowsRepeat && selected
                          ? Text('$count×',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _accent))
                          : Icon(
                              g.isSingle
                                  ? (selected ? Icons.radio_button_checked : Icons.radio_button_off)
                                  : (selected ? Icons.check_box : Icons.check_box_outline_blank),
                              size: 18,
                              color: selected ? _accent : Colors.black45,
                            ),
                    ),
                  ),
                  if (g.allowsRepeat && selected)
                    Positioned(
                      top: 0,
                      left: 0,
                      // 44px hit area (touch-target minimum) around a 32px button;
                      // opaque so taps in the padding don't fall through to the card.
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _decrement(g, v),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 4),
                              ],
                            ),
                            child: const Icon(Icons.remove_rounded, size: 22, color: Color(0xFF1A1A1A)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Fixed 2-line slot with the name vertically centered (as on
                  // MenuItemCard), so long names never push the image or price.
                  SizedBox(
                    height: _nameSlot,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.25,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                          color: const Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    priceText,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: selected ? const Color(0xFF8A6D3B) : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _image(String? url) {
    final placeholder = Container(
      color: const Color(0xFFF3F1EC),
      child: const Center(child: Icon(Icons.restaurant_rounded, size: 30, color: Color(0xFFBDB6A8))),
    );
    if (url == null || url.isEmpty) return placeholder;
    return Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
  }
}
