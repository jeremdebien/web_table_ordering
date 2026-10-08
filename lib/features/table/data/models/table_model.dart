class TableModel {
  final int id;
  final int tableId;
  final String? uuid;
  final String description;
  final bool isActive;
  final int groundId;
  final DateTime createdAt;

  // Floor-plan layout (local schema, see local_supabase_migration/0006_table_layout.sql).
  // Defaulted so existing single-table lookups (getTableByUuid/getTableByName)
  // that don't project these columns are unaffected.
  final double xLoc;
  final double yLoc;
  final double rotation;
  final String shape;
  final int capacity;
  final int gridWidth;
  final int gridHeight;
  final String seatLayout;

  /// Per-table blueprint overrides (migration 0068); null = use the ground's.
  final double? nameScale;
  final double? chairWidthScale;
  final double? chairHeightScale;

  TableModel({
    required this.id,
    required this.tableId,
    this.uuid,
    required this.description,
    this.isActive = false,
    required this.groundId,
    required this.createdAt,
    this.xLoc = 0,
    this.yLoc = 0,
    this.rotation = 0,
    this.shape = 'square',
    this.capacity = 4,
    this.gridWidth = 1,
    this.gridHeight = 1,
    this.seatLayout = 'all',
    this.nameScale,
    this.chairWidthScale,
    this.chairHeightScale,
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
      xLoc: (json['x_loc'] as num?)?.toDouble() ?? 0,
      yLoc: (json['y_loc'] as num?)?.toDouble() ?? 0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      shape: json['table_shape'] as String? ?? 'square',
      capacity: (json['capacity'] as num?)?.toInt() ?? 4,
      gridWidth: (json['grid_width'] as num?)?.toInt() ?? 1,
      gridHeight: (json['grid_height'] as num?)?.toInt() ?? 1,
      seatLayout: json['seat_layout'] as String? ?? 'all',
      nameScale: (json['name_scale'] as num?)?.toDouble(),
      chairWidthScale: (json['chair_width_scale'] as num?)?.toDouble(),
      chairHeightScale: (json['chair_height_scale'] as num?)?.toDouble(),
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
      'x_loc': xLoc,
      'y_loc': yLoc,
      'rotation': rotation,
      'table_shape': shape,
      'capacity': capacity,
      'grid_width': gridWidth,
      'grid_height': gridHeight,
      'seat_layout': seatLayout,
      'name_scale': nameScale,
      'chair_width_scale': chairWidthScale,
      'chair_height_scale': chairHeightScale,
    };
  }
}
