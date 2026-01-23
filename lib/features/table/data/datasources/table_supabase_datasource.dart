import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/models/table_model.dart';

class TableSupabaseDataSource {
  final SupabaseClient _client;

  TableSupabaseDataSource(this._client);

  int get _branchId => int.tryParse(dotenv.env['BRANCH_ID'] ?? '') ?? 0;

  Future<TableModel> getTableByUuid(String uuid) async {
    try {
      final response = await _client.from('tables').select().eq('table_uuid', uuid).eq('branch_id', _branchId).single();

      return TableModel.fromJson(response);
    } catch (e) {
      throw Exception('Failed to fetch table: $e');
    }
  }
}
