class TableModel {
  final int id;
  final int tableId;
  final String? uuid;
  final String description;
  final bool isActive;
  final int groundId;
  final DateTime createdAt;

  TableModel({
    required this.id,
    required this.tableId,
    this.uuid,
    required this.description,
    this.isActive = false,
    required this.groundId,
    required this.createdAt,
  });

  factory TableModel.fromJson(Map<String, dynamic> json) {
    return TableModel(
      id: json['id'] as int,
      tableId: json['table_id'] as int,
      uuid: json['table_uuid'] as String?,
      description: json['table_desc'] as String,
      isActive: (json['table_status'] as int?) == 1,
      groundId: json['ground_id'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'table_id': tableId,
      'table_uuid': uuid,
      'table_desc': description,
      'table_status': isActive ? 1 : 0,
      'ground_id': groundId,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
