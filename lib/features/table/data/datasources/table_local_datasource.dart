import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/models/table_model.dart';
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
}
