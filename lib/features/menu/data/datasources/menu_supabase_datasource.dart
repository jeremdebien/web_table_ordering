import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';

class MenuSupabaseDataSource {
  final SupabaseClient _client;

  MenuSupabaseDataSource(this._client);

  // Departments
  Future<List<DepartmentModel>> getDepartments() async {
    final response = await _client.from('departments').select().eq('is_active', true).order('name');

    return (response as List).map((e) => DepartmentModel.fromJson(e)).toList();
  }

  // Categories
  Future<List<CategoryModel>> getCategories({int? departmentId}) async {
    var query = _client.from('categories').select().eq('is_active', true);

    if (departmentId != null) {
      query = query.eq('department_id', departmentId);
    }

    final response = await query.order('name');
    return (response as List).map((e) => CategoryModel.fromJson(e)).toList();
  }

  // Items
  Future<List<ItemModel>> getItems({int? categoryId}) async {
    var query = _client.from('items').select().eq('is_available', true);

    if (categoryId != null) {
      query = query.eq('category_id', categoryId);
    }

    final response = await query.order('name');
    return (response as List).map((e) => ItemModel.fromJson(e)).toList();
  }

  // Storage: Get item image
  String getItemImageUrl(String imagePath) {
    return _client.storage.from('items').getPublicUrl(imagePath);
  }
}
