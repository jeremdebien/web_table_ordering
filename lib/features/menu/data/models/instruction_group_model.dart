import 'instruction_choice_model.dart';

/// A user-defined "special instruction" question attached to a menu item
/// (e.g. "How done?"). Non-priced; offers suggested [choices], a free-text
/// field ([allowFreeText]), or both; single or multiple selection; and can be
/// required via [minSelect]/[maxSelect].
class InstructionGroup {
  final int id;
  final String itemBarcode;
  final String label;
  final int minSelect;

  /// Max selectable choices. `null` = unlimited. `1` = single-select.
  final int? maxSelect;
  final bool allowFreeText;
  final int displayOrder;
  final List<InstructionChoice> choices;

  const InstructionGroup({
    required this.id,
    required this.itemBarcode,
    required this.label,
    this.minSelect = 0,
    this.maxSelect = 1,
    this.allowFreeText = false,
    this.displayOrder = 0,
    this.choices = const [],
  });

  /// Required ⇔ at least one selection is mandated.
  bool get isRequired => minSelect > 0;

  /// Single-select ⇔ at most one choice.
  bool get isSingleSelect => maxSelect == 1;

  factory InstructionGroup.fromJson(
    Map<String, dynamic> json, {
    List<InstructionChoice> choices = const [],
  }) {
    bool toBool(dynamic v) => v == 1 || v == true;
    return InstructionGroup(
      id: (json['id'] as num).toInt(),
      itemBarcode: json['item_barcode'] as String,
      label: json['label'] as String,
      minSelect: (json['min_select'] as num?)?.toInt() ?? 0,
      maxSelect: (json['max_select'] as num?)?.toInt(),
      allowFreeText: toBool(json['allow_free_text']),
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
      choices: choices,
    );
  }
}
