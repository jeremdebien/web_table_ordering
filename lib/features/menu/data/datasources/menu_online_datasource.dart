import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/config/app_config.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import 'menu_data_source.dart';

/// Online (hosted) menu catalog: plural, branch-scoped tables.
class OnlineMenuDataSource implements MenuDataSource {
  final SupabaseClient _client;

  OnlineMenuDataSource(this._client);

  int get _branchId => AppConfig.branchId;

  // Departments
  @override
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
  @override
  Future<List<CategoryModel>> getCategories({int? departmentId}) async {
    var query = _client.from('categories').select().eq('status', true).eq('branch_id', _branchId);

    if (departmentId != null) {
      query = query.eq('department_id', departmentId);
    }

    final response = await query.order('category_name');
    return (response as List).map((e) => CategoryModel.fromJson(e)).toList();
  }

  // Items
  @override
  Future<List<ItemModel>> getItems({int? categoryId}) async {
    var query = _client.from('items').select().eq('item_status', 1).eq('branch_id', _branchId);

    if (categoryId != null) {
      query = query.eq('category_id', categoryId);
    }

    final response = await query.order('item_name');
    return (response as List).map((e) => ItemModel.fromJson(e)).toList();
  }

  // Storage: Get item image
  @override
  String getItemImageUrl(String imagePath) {
    return _client.storage.from('items').getPublicUrl(imagePath);
  }
}
