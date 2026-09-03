/// A named menu configuration ("Weekday Dinner", "Weekend Lunch", …) that holds
/// its own per-item enabled/disabled config. Exactly one group is [isActive] at
/// a time; the active group is the source of truth for the customer-facing web
/// menu (live-override model, migration 0052).
class MenuGroupModel {
  final int id;
  final String name;
  final bool isActive;
  final int sortOrder;

  const MenuGroupModel({
    required this.id,
    required this.name,
    this.isActive = false,
    this.sortOrder = 0,
  });

  factory MenuGroupModel.fromJson(Map<String, dynamic> json) {
    return MenuGroupModel(
      id: json['id'] as int,
      name: (json['name'] as String?) ?? '',
      // Stored as INTEGER (1/0) in the consolidator schema.
      isActive: (json['is_active'] as int?) == 1,
      sortOrder: (json['sort_order'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'is_active': isActive ? 1 : 0,
      'sort_order': sortOrder,
    };
  }

  MenuGroupModel copyWith({
    int? id,
    String? name,
    bool? isActive,
    int? sortOrder,
  }) {
    return MenuGroupModel(
      id: id ?? this.id,
      name: name ?? this.name,
      isActive: isActive ?? this.isActive,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}
