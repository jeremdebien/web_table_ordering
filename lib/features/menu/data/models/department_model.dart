class DepartmentModel {
  final int id;
  final String name;
  final String? description;
  final String? imageUrl;
  final bool isActive;

  DepartmentModel({required this.id, required this.name, this.description, this.imageUrl, this.isActive = true});

  factory DepartmentModel.fromJson(Map<String, dynamic> json) {
    return DepartmentModel(
      id: json['id'] as int,
      name: json['name'] as String,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name, 'description': description, 'image_url': imageUrl, 'is_active': isActive};
  }
}
