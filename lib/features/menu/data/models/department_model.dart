class DepartmentModel {
  final int id;
  final String name;
  final String? description;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final int? deptId;

  DepartmentModel({
    required this.id,
    required this.name,
    this.description,
    this.isActive = false,
    required this.createdAt,
    this.updatedAt,
    this.deptId,
  });

  factory DepartmentModel.fromJson(Map<String, dynamic> json) {
    return DepartmentModel(
      id: json['id'] as int,
      name: json['dept_name'] as String,
      description: json['dept_description'] as String?,
      isActive: json['status'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null ? DateTime.parse(json['updated_at'] as String) : null,
      deptId: json['dept_id'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'dept_name': name,
      'dept_description': description,
      'status': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'dept_id': deptId,
    };
  }
}
