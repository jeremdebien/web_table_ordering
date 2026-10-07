import 'dart:convert';

/// A blueprint structure from `table_layout_items` (wall, door, fill, cashier,
/// text, area, marker). Mirrors kwikpos_lite `TableLayoutItem`; [props] holds
/// the text/area/marker style, stored as a JSON string (migration 0069).
class LayoutItemModel {
  final int id;
  final String description;
  final String type;
  final int groundId;
  final double xLoc;
  final double yLoc;
  final double width;
  final double height;
  final double rotation;
  final Map<String, dynamic> props;

  const LayoutItemModel({
    required this.id,
    required this.description,
    required this.type,
    required this.groundId,
    required this.xLoc,
    required this.yLoc,
    this.width = 100.0,
    this.height = 20.0,
    this.rotation = 0.0,
    this.props = const {},
  });

  factory LayoutItemModel.fromJson(Map<String, dynamic> json) {
    return LayoutItemModel(
      id: (json['layout_item_id'] as num).toInt(),
      description: json['layout_item_desc']?.toString() ?? '',
      type: json['layout_item_type']?.toString() ?? '',
      groundId: (json['ground'] as num?)?.toInt() ?? 0,
      xLoc: (json['x_loc'] as num?)?.toDouble() ?? 0,
      yLoc: (json['y_loc'] as num?)?.toDouble() ?? 0,
      width: (json['width'] as num?)?.toDouble() ?? 100.0,
      height: (json['height'] as num?)?.toDouble() ?? 20.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      props: _decodeProps(json['props']),
    );
  }

  static Map<String, dynamic> _decodeProps(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }
}
