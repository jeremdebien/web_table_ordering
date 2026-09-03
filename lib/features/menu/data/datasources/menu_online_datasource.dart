import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/config/app_config.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import '../models/instruction_group_model.dart';
import '../models/menu_group_model.dart';
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
    // Web-visibility flag `is_available_in_web_table` (migration 0046) is a
    // consolidator/local-mode column; the hosted `items` schema may not have it
    // yet, so we intentionally do NOT filter on it here to avoid breaking the
    // hosted path. Add `.eq('is_available_in_web_table', 1)` once the column
    // ships to the hosted schema.
    var query = _client.from('items').select().eq('item_status', 1).eq('branch_id', _branchId);

    if (categoryId != null) {
      query = query.eq('category_id', categoryId);
    }

    final response = await query.order('item_name');
    return (response as List).map((e) => ItemModel.fromJson(e)).toList();
  }

  @override
  Future<List<ItemModel>> getAllItemsForCuration() async {
    final response =
        await _client.from('items').select().eq('item_status', 1).eq('branch_id', _branchId).order('item_name');
    return (response as List).map((e) => ItemModel.fromJson(e)).toList();
  }

  @override
  Future<void> setItemWebVisibility(String barcode, bool visible) async {
    await _client
        .from('items')
        .update({'is_available_in_web_table': visible ? 1 : 0})
        .eq('barcode', barcode)
        .eq('branch_id', _branchId);
  }

  // Storage: Get item image
  @override
  String getItemImageUrl(String imagePath) {
    return _client.storage.from('items').getPublicUrl(imagePath);
  }

  // Special instructions are a local-mode feature; online path is unchanged.
  @override
  Future<List<InstructionGroup>> getItemInstructions(String barcode, {int? categoryId}) async => [];

  // ── Menu groups ────────────────────────────────────────────────────────────
  // TODO(online): menu groups are a local-mode feature for now (migration 0052).
  // The hosted `items` schema is plural + branch-scoped and has no menu_group
  // tables yet; implement once they ship to the hosted schema.
  static const _unsupported =
      'Menu groups are not yet supported in online (hosted) mode.';

  @override
  Future<List<MenuGroupModel>> getMenuGroups() async => [];

  @override
  Future<MenuGroupModel> createMenuGroup(String name) async =>
      throw UnimplementedError(_unsupported);

  @override
  Future<void> renameMenuGroup(int id, String name) async =>
      throw UnimplementedError(_unsupported);

  @override
  Future<void> deleteMenuGroup(int id) async => throw UnimplementedError(_unsupported);

  @override
  Future<void> setActiveMenuGroup(int id) async => throw UnimplementedError(_unsupported);

  @override
  Future<Map<String, bool>> getMenuGroupItems(int id) async => {};

  @override
  Future<void> setMenuGroupItems(int id, Map<String, bool> updates) async =>
      throw UnimplementedError(_unsupported);
}
