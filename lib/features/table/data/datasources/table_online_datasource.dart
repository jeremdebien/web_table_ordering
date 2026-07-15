import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/config/app_config.dart';
import '../../data/models/table_model.dart';
import 'table_data_source.dart';

/// Online (hosted) table lookup: branch-scoped, keyed by `table_uuid`.
class OnlineTableDataSource implements TableDataSource {
  final SupabaseClient _client;

  OnlineTableDataSource(this._client);

  int get _branchId => AppConfig.branchId;

  @override
  Future<TableModel> getTableByUuid(String uuid) async {
    try {
      final response = await _client.from('tables').select().eq('table_uuid', uuid).eq('branch_id', _branchId).single();

      return TableModel.fromJson(response);
    } catch (e) {
      throw Exception('Failed to fetch table: $e');
    }
  }

  @override
  Future<TableModel> getTableByName(String name) async {
    try {
      final response = await _client.from('tables').select().ilike('table_desc', name.trim()).eq('branch_id', _branchId).maybeSingle();
      if (response == null) {
        throw Exception('Table "$name" not found.');
      }
      return TableModel.fromJson(response);
    } catch (e) {
      throw Exception('Failed to fetch table by name: $e');
    }
  }
}
