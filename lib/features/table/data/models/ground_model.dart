class GroundModel {
  final int id;
  final String description;
  final bool isActive;
  final DateTime createdAt;
  final int groundId;

  // Floor-plan layout (local schema, see local_supabase_migration/0006_table_layout.sql).
  // Defaulted so the online `fromJson` — which does not carry these columns —
  // still parses to sensible values.
  final bool isCustomLayout;
  final double tableSize;
  final double canvasWidth;
  final double canvasHeight;
  final double initialZoom;

  GroundModel({
    required this.id,
    required this.description,
    this.isActive = false,
    required this.createdAt,
    required this.groundId,
    this.isCustomLayout = false,
    this.tableSize = 64,
    this.canvasWidth = 1200.0,
    this.canvasHeight = 800.0,
    this.initialZoom = 1.0,
  });

  factory GroundModel.fromJson(Map<String, dynamic> json) {
    bool toBool(dynamic value) {
      if (value is bool) return value;
      if (value is int) return value == 1;
      return false;
    }

    return GroundModel(
      id: json['id'] as int,
      description: json['ground_desc'] as String,
      isActive: (json['ground_status'] as int?) == 1,
      createdAt: DateTime.parse(json['created_at'] as String),
      groundId: json['ground_id'] as int,
      isCustomLayout: toBool(json['is_custom_layout']),
      tableSize: (json['table_size'] as num?)?.toDouble() ?? 64,
      canvasWidth: (json['canvas_width'] as num?)?.toDouble() ?? 1200.0,
      canvasHeight: (json['canvas_height'] as num?)?.toDouble() ?? 800.0,
      initialZoom: (json['initial_zoom'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'ground_desc': description,
      'ground_status': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'ground_id': groundId,
      'is_custom_layout': isCustomLayout ? 1 : 0,
      'table_size': tableSize,
      'canvas_width': canvasWidth,
      'canvas_height': canvasHeight,
      'initial_zoom': initialZoom,
    };
  }
}
