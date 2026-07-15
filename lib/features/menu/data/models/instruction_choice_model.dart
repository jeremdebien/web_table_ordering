/// A suggested choice for an item special-instruction question.
/// Plain label — not backed by a product, no price.
class InstructionChoice {
  final int id;
  final int groupId;
  final String label;
  final int displayOrder;

  const InstructionChoice({
    required this.id,
    required this.groupId,
    required this.label,
    this.displayOrder = 0,
  });

  factory InstructionChoice.fromJson(Map<String, dynamic> json) {
    return InstructionChoice(
      id: (json['id'] as num).toInt(),
      groupId: (json['group_id'] as num).toInt(),
      label: json['label'] as String,
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
    );
  }
}
