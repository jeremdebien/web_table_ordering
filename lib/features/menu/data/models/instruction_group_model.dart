import 'dart:convert';
import 'instruction_choice_model.dart';

/// A user-defined "special instruction" question attached to a menu item, category,
/// or globally across all items (e.g. "How done?", "Sugar level").
/// Non-priced; offers suggested [choices], a free-text field ([allowFreeText]),
/// or both; single or multiple selection; and can be required via [minSelect]/[maxSelect].
class InstructionGroup {
  final int id;
  final String scopeType; // 'global', 'category', 'item'
  final int? categoryId;
  final String? itemBarcode;
  final List<String> excludedItemBarcodes;
  final String label;
  final int minSelect;

  /// Max selectable choices. `null` = unlimited. `1` = single-select.
  final int? maxSelect;
  final bool allowFreeText;
  final int displayOrder;
  final List<InstructionChoice> choices;

  const InstructionGroup({
    required this.id,
    this.scopeType = 'item',
    this.categoryId,
    this.itemBarcode,
    this.excludedItemBarcodes = const [],
    required this.label,
    this.minSelect = 0,
    this.maxSelect = 1,
    this.allowFreeText = false,
    this.displayOrder = 0,
    this.choices = const [],
  });

  bool get isGlobal => scopeType == 'global';
  bool get isCategory => scopeType == 'category';
  bool get isItem => scopeType == 'item';

  /// Required ⇔ at least one selection is mandated.
  bool get isRequired => minSelect > 0;

  /// Single-select ⇔ at most one choice.
  bool get isSingleSelect => maxSelect == 1;

  bool isExcludedFor(String barcode) => excludedItemBarcodes.contains(barcode);

  factory InstructionGroup.fromJson(
    Map<String, dynamic> json, {
    List<InstructionChoice> choices = const [],
  }) {
    bool toBool(dynamic v) => v == 1 || v == true;

    List<String> parseExcluded(dynamic v) {
      if (v == null) return const [];
      if (v is String && v.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(v);
          if (decoded is List) return decoded.map((e) => e.toString()).toList();
        } catch (_) {}
      }
      if (v is List) return v.map((e) => e.toString()).toList();
      return const [];
    }

    return InstructionGroup(
      id: (json['id'] as num).toInt(),
      scopeType: (json['scope_type'] as String?)?.trim().toLowerCase() ?? 'item',
      categoryId: (json['category_id'] as num?)?.toInt(),
      itemBarcode: json['item_barcode'] as String?,
      excludedItemBarcodes: parseExcluded(json['excluded_item_barcodes']),
      label: json['label'] as String,
      minSelect: (json['min_select'] as num?)?.toInt() ?? 0,
      maxSelect: (json['max_select'] as num?)?.toInt(),
      allowFreeText: toBool(json['allow_free_text']),
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
      choices: choices,
    );
  }
}
