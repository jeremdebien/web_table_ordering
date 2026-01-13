class CategoryModel {
  final int id;
  final int departmentId;
  final String name;
  final String? description;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final int? categoryId;

  CategoryModel({
    required this.id,
    required this.departmentId,
    required this.name,
    this.description,
    this.isActive = false,
    required this.createdAt,
    this.updatedAt,
    this.categoryId,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id'] as int,
      departmentId: json['department_id'] as int,
      name: json['category_name'] as String,
      description: json['category_desc'] as String?,
      isActive: json['status'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null ? DateTime.parse(json['updated_at'] as String) : null,
      categoryId: json['category_id'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'department_id': departmentId,
      'category_name': name,
      'category_desc': description,
      'status': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'category_id': categoryId,
    };
  }
}
