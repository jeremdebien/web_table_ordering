import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';

class MenuSupabaseDataSource {
  final SupabaseClient _client;

  MenuSupabaseDataSource(this._client);

  int get _branchId => int.tryParse(dotenv.env['BRANCH_ID'] ?? '') ?? 0;

  // Departments
  Future<List<DepartmentModel>> getDepartments() async {
    final response = await _client
        .from('departments')
        .select()
        .eq('status', true)
        .eq('branch_id', _branchId)
        .order('dept_name');

    return (response as List).map((e) => DepartmentModel.fromJson(e)).toList();
  }

  // Categories
  Future<List<CategoryModel>> getCategories({int? departmentId}) async {
    var query = _client.from('categories').select().eq('status', true).eq('branch_id', _branchId);

    if (departmentId != null) {
      query = query.eq('department_id', departmentId);
    }

    final response = await query.order('category_name');
    return (response as List).map((e) => CategoryModel.fromJson(e)).toList();
  }

  // Items
  Future<List<ItemModel>> getItems({int? categoryId}) async {
    var query = _client.from('items').select().eq('item_status', 1).eq('branch_id', _branchId);

    if (categoryId != null) {
      query = query.eq('category_id', categoryId);
    }

    final response = await query.order('item_name');
    return (response as List).map((e) => ItemModel.fromJson(e)).toList();
  }

  // Storage: Get item image
  String getItemImageUrl(String imagePath) {
    return _client.storage.from('items').getPublicUrl(imagePath);
  }
}
