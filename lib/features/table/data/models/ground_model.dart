class GroundModel {
  final int id;
  final String description;
  final bool isActive;
  final DateTime createdAt;
  final int groundId;

  GroundModel({
    required this.id,
    required this.description,
    this.isActive = false,
    required this.createdAt,
    required this.groundId,
  });

  factory GroundModel.fromJson(Map<String, dynamic> json) {
    return GroundModel(
      id: json['id'] as int,
      description: json['ground_desc'] as String,
      isActive: (json['ground_status'] as int?) == 1,
      createdAt: DateTime.parse(json['created_at'] as String),
      groundId: json['ground_id'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'ground_desc': description,
      'ground_status': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'ground_id': groundId,
    };
  }
}
