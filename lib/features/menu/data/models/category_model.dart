class CategoryModel {
  final int id;
  final int departmentId;
  final String name;
  final String? description;
  final String? imageUrl;
  final bool isActive;

  CategoryModel({
    required this.id,
    required this.departmentId,
    required this.name,
    this.description,
    this.imageUrl,
    this.isActive = true,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id'] as int,
      departmentId: json['department_id'] as int,
      name: json['name'] as String,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'department_id': departmentId,
      'name': name,
      'description': description,
      'image_url': imageUrl,
      'is_active': isActive,
    };
  }
}
