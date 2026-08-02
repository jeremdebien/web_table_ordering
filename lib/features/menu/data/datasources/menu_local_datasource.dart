import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import '../models/instruction_group_model.dart';
import '../models/instruction_choice_model.dart';
import 'menu_data_source.dart';

/// Local (self-hosted) menu catalog targeting the local_supabase_migration
/// schema: singular `"Department"` / `"Category"` / `item` tables with `*_desc`
/// columns, integer status flags, and no `branch_id`. Rows are mapped into the
/// JSON shape the shared models expect.
class LocalMenuDataSource implements MenuDataSource {
  final SupabaseClient _client;

  LocalMenuDataSource(this._client);

  /// Shared Storage bucket the POS uploads item images to (see the POS
  /// consolidator's migration 0025). Item rows reference an object inside it via
  /// `image_object` (e.g. `items/<barcode>.jpg`).
  static const String _imageBucket = 'master-file';

  static bool _flag(dynamic v) => v == 1 || v == true;

  static String _now() => DateTime.now().toIso8601String();

  @override
  Future<List<DepartmentModel>> getDepartments() async {
    final response = await _client.from('Department').select().eq('dept_status', 1).order('dept_desc');

    return (response as List).map((row) {
      return DepartmentModel.fromJson({
        'id': row['dept_id'],
        'dept_name': row['dept_desc'],
        'dept_description': row['dept_desc'],
        'status': _flag(row['dept_status']),
        'created_at': row['d_tran_date'] ?? _now(),
        'dept_id': row['dept_id'],
      });
    }).toList();
  }

  @override
  Future<List<CategoryModel>> getCategories({int? departmentId}) async {
    var query = _client.from('Category').select().eq('category_status', 1);

    if (departmentId != null) {
      query = query.eq('department', departmentId);
    }

    final response = await query.order('category_desc');
    return (response as List).map((row) {
      return CategoryModel.fromJson({
        'id': row['category_id'],
        'department_id': row['department'] ?? 0,
        'category_name': row['category_desc'],
        'category_desc': row['category_desc'],
        'status': _flag(row['category_status']),
        'created_at': row['d_tran_date'] ?? _now(),
        'category_id': row['category_id'],
        'ordering_index': row['ordering_index'],
        'is_available_in_web_table': _flag(row['is_available_in_web_table']),
      });
    }).toList();
  }

  @override
  Future<List<ItemModel>> getItems({int? categoryId}) async {
    var query = _client.from('item').select().eq('item_status', 1);

    if (categoryId != null) {
      query = query.eq('category', categoryId);
    }

    final response = await query.order('item_desc');
    return (response as List).map((row) {
      return ItemModel.fromJson({
        'id': row['id'],
        'barcode': row['barcode'] ?? '',
        'item_code': row['item_code'] ?? '',
        'item_name': row['item_desc'],
        'item_desc': row['item_desc'],
        'item_status': row['item_status'],
        'print_desc': row['print_desc'],
        'department_id': row['dept'] ?? 0,
        'category_id': row['category'] ?? 0,
        'cost_price': row['cost_price'],
        'mark_up': row['mark_up'],
        'price': row['price'] ?? 0,
        'price_1': row['price_1'],
        'price_2': row['price_2'],
        'price_3': row['price_3'],
        'price_4': row['price_4'],
        'price_5': row['price_5'],
        'assigned_printer': row['assigned_printer'],
        'is_disc_exempt': _flag(row['disc_exempt']),
        'is_non_vat': _flag(row['non_vat']),
        // `disp_image` is a POS-terminal-local file path and means nothing to a
        // browser; the shared, downloadable image is keyed by `image_object`
        // inside the `master-file` bucket. ItemModel.displayImage prepends the
        // storage `.../object/public/` base, so include the bucket name here.
        'display_image':
            row['image_object'] != null ? '$_imageBucket/${row['image_object']}' : null,
        'created_at': row['d_tran_date'] ?? _now(),
        'update_at': row['date_change'],
      });
    }).toList();
  }

  @override
  String getItemImageUrl(String imagePath) {
    return _client.storage.from(_imageBucket).getPublicUrl(imagePath);
  }

  @override
  Future<List<InstructionGroup>> getItemInstructions(String barcode) async {
    final groupRows = await _client
        .from('item_instruction_group')
        .select()
        .eq('item_barcode', barcode)
        .eq('group_status', 1)
        .order('display_order');

    final groups = List<Map<String, dynamic>>.from(groupRows as List);
    if (groups.isEmpty) return [];

    final groupIds = groups.map((g) => (g['id'] as num).toInt()).toList();
    final choiceRows = await _client
        .from('item_instruction_choice')
        .select()
        .inFilter('group_id', groupIds)
        .eq('choice_status', 1)
        .order('display_order');

    // Bucket choices by their group.
    final choicesByGroup = <int, List<InstructionChoice>>{};
    for (final row in (choiceRows as List)) {
      final choice = InstructionChoice.fromJson(Map<String, dynamic>.from(row));
      choicesByGroup.putIfAbsent(choice.groupId, () => []).add(choice);
    }

    return groups.map((g) {
      final id = (g['id'] as num).toInt();
      return InstructionGroup.fromJson(g, choices: choicesByGroup[id] ?? const []);
    }).toList();
  }
}
