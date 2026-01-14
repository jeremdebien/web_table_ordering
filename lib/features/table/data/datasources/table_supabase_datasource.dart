import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/models/table_model.dart';

class TableSupabaseDataSource {
  final SupabaseClient _client;

  TableSupabaseDataSource(this._client);

  Future<TableModel> getTableByUuid(String uuid) async {
    try {
      final response = await _client.from('tables').select().eq('table_uuid', uuid).single();

      return TableModel.fromJson(response);
    } catch (e) {
      throw Exception('Failed to fetch table: $e');
    }
  }
}
