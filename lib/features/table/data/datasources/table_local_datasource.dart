import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/models/ground_model.dart';
import '../../data/models/table_model.dart';
import '../../data/models/layout_item_model.dart';
import 'table_data_source.dart';

/// Local (self-hosted) table lookup targeting the local_supabase_migration
/// schema: `tables` keyed by numeric `table_id`, with a `table_uuid` column
/// added by migration 0015. No branch filtering (single-branch DB).
class LocalTableDataSource implements TableDataSource {
  final SupabaseClient _client;

  LocalTableDataSource(this._client);

  @override
  Future<TableModel> getTableByUuid(String uuid) async {
    try {
      final row = await _client.from('tables').select().eq('table_uuid', uuid).single();

      return TableModel.fromJson({
        'id': (row['table_id'] as num).toInt(),
        'table_id': (row['table_id'] as num).toInt(),
        'table_uuid': row['table_uuid'],
        'table_desc': row['table_desc'],
        // Local `table_status` is boolean; the model reads it as an int flag.
        'table_status': (row['table_status'] == true) ? 1 : 0,
        'ground_id': row['ground'] ?? 0,
        'created_at': row['created_at'] ?? DateTime.now().toIso8601String(),
      });
    } catch (e) {
      throw Exception('Failed to fetch table: $e');
    }
  }

  @override
  Future<TableModel> getTableByName(String name) async {
    try {
      final row = await _client.from('tables').select().ilike('table_desc', name.trim()).maybeSingle();
      if (row == null) {
        throw Exception('Table "$name" not found.');
      }
      return TableModel.fromJson({
        'id': (row['table_id'] as num).toInt(),
        'table_id': (row['table_id'] as num).toInt(),
        'table_uuid': row['table_uuid'],
        'table_desc': row['table_desc'],
        // Local `table_status` is boolean; the model reads it as an int flag.
        'table_status': (row['table_status'] == true) ? 1 : 0,
        'ground_id': row['ground'] ?? 0,
        'created_at': row['created_at'] ?? DateTime.now().toIso8601String(),
      });
    } catch (e) {
      throw Exception('Failed to fetch table by name: $e');
    }
  }

  @override
  Future<List<GroundModel>> getGrounds() async {
    try {
      // Admin-chosen order first (Postgres ASC sorts NULL ordering_index
      // last), creation order as the tiebreaker — same as the POS, so the
      // floor plan lists areas and defaults to grounds.first identically.
      final rows = await _client
          .from('ground')
          .select()
          .order('ordering_index', ascending: true)
          .order('created_at', ascending: true);
      return List<Map<String, dynamic>>.from(rows as List)
          .where((row) => row['ground_status'] == true)
          .map(
            (row) => GroundModel.fromJson({
              'id': (row['ground_id'] as num).toInt(),
              'ground_id': (row['ground_id'] as num).toInt(),
              'ground_desc': row['ground_desc'],
              'ground_status': (row['ground_status'] == true) ? 1 : 0,
              'is_custom_layout': (row['is_custom_layout'] == true) ? 1 : 0,
              'table_size': row['table_size'],
              'canvas_width': row['canvas_width'],
              'canvas_height': row['canvas_height'],
              'initial_zoom': row['initial_zoom'],
              'table_name_scale': row['table_name_scale'],
              'chair_width_scale': row['chair_width_scale'],
              'chair_height_scale': row['chair_height_scale'],
              'ordering_index': row['ordering_index'],
              'created_at': row['created_at'] ?? DateTime.now().toIso8601String(),
            }),
          )
          .toList();
    } catch (e) {
      throw Exception('Failed to fetch grounds: $e');
    }
  }

  @override
  Future<List<TableModel>> getTables() async {
    try {
      final rows = await _client.from('tables').select();
      return List<Map<String, dynamic>>.from(rows as List)
          .where((row) => row['table_status'] == true)
          .map(
            (row) => TableModel.fromJson({
              'id': (row['table_id'] as num).toInt(),
              'table_id': (row['table_id'] as num).toInt(),
              'table_uuid': row['table_uuid'],
              'table_desc': row['table_desc'],
              'table_status': (row['table_status'] == true) ? 1 : 0,
              'ground_id': row['ground'] ?? 0,
              'x_loc': row['x_loc'],
              'y_loc': row['y_loc'],
              'rotation': row['rotation'],
              'table_shape': row['table_shape'],
              'capacity': row['capacity'],
              'grid_width': row['grid_width'],
              'grid_height': row['grid_height'],
              'seat_layout': row['seat_layout'],
              'name_scale': row['name_scale'],
              'chair_width_scale': row['chair_width_scale'],
              'chair_height_scale': row['chair_height_scale'],
              'created_at': row['created_at'] ?? DateTime.now().toIso8601String(),
            }),
          )
          .toList();
    } catch (e) {
      throw Exception('Failed to fetch tables: $e');
    }
  }

  @override
  Future<List<LayoutItemModel>> getLayoutItems() async {
    try {
      final rows = await _client.from('table_layout_items').select();
      return List<Map<String, dynamic>>.from(rows as List).map(LayoutItemModel.fromJson).toList();
    } catch (e) {
      throw Exception('Failed to fetch layout items: $e');
    }
  }
}
