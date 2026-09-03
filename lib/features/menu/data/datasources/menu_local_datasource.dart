import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import '../models/instruction_group_model.dart';
import '../models/instruction_choice_model.dart';
import '../models/menu_group_model.dart';
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
        'ordering_index': row['ordering_index'],
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
    // Live-override resolution (migration 0052): if a menu group is active, it is
    // the source of truth -- show only its enabled barcodes. With NO active
    // group, fall back to the per-item `is_available_in_web_table` flag
    // (migration 0047) so the menu keeps working before any group is created.
    final activeId = await _activeMenuGroupId();

    var query = _client.from('item').select().eq('item_status', 1);

    if (activeId != null) {
      final config = await getMenuGroupItems(activeId);
      final enabled = [
        for (final e in config.entries)
          if (e.value) e.key,
      ];
      // An active group with nothing enabled means an empty menu.
      if (enabled.isEmpty) return [];
      query = query.inFilter('barcode', enabled);
    } else {
      query = query.eq('is_available_in_web_table', 1);
    }

    if (categoryId != null) {
      query = query.eq('category', categoryId);
    }

    final response = await query.order('item_desc');
    return (response as List).map((row) => _mapItemRow(row)).toList();
  }

  @override
  Future<List<ItemModel>> getAllItemsForCuration() async {
    // Staff curation: every orderable item, regardless of web visibility.
    final response =
        await _client.from('item').select().eq('item_status', 1).order('item_desc');
    return (response as List).map((row) => _mapItemRow(row)).toList();
  }

  @override
  Future<void> setItemWebVisibility(String barcode, bool visible) async {
    await _client
        .from('item')
        .update({'is_available_in_web_table': visible ? 1 : 0}).eq('barcode', barcode);
  }

  /// Maps a consolidator `item` row into the JSON shape [ItemModel] expects.
  ItemModel _mapItemRow(Map<String, dynamic> row) {
    return ItemModel.fromJson({
      'id': row['id'],
      'barcode': row['barcode'] ?? '',
      'item_code': row['item_code'] ?? '',
      'item_name': row['item_desc'],
      'item_desc': row['item_desc'],
      'item_status': row['item_status'],
      'is_available_in_web_table': row['is_available_in_web_table'],
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
      'button_index': row['button_index'],
      'created_at': row['d_tran_date'] ?? _now(),
      'update_at': row['date_change'],
    });
  }

  @override
  String getItemImageUrl(String imagePath) {
    return _client.storage.from(_imageBucket).getPublicUrl(imagePath);
  }

  @override
  Future<List<InstructionGroup>> getItemInstructions(String barcode, {int? categoryId}) async {
    try {
      final List<String> orClauses = [
        'scope_type.eq.global',
        'and(scope_type.eq.item,item_barcode.eq.$barcode)',
        'item_barcode.eq.$barcode', // backward compatibility for legacy unmigrated rows
      ];
      if (categoryId != null) {
        orClauses.add('and(scope_type.eq.category,category_id.eq.$categoryId)');
      }

      final groupRows = await _client
          .from('item_instruction_group')
          .select()
          .or(orClauses.join(','))
          .eq('group_status', 1)
          .order('display_order');

      final rawGroups = List<Map<String, dynamic>>.from(groupRows as List);
      if (rawGroups.isEmpty) return [];

      final groupIds = rawGroups.map((g) => (g['id'] as num).toInt()).toList();
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

      final groups = rawGroups.map((g) {
        final id = (g['id'] as num).toInt();
        return InstructionGroup.fromJson(g, choices: choicesByGroup[id] ?? const []);
      }).where((g) => !g.isExcludedFor(barcode)).toList();

      // Sort by display_order ascending, then id
      groups.sort((a, b) {
        if (a.displayOrder != b.displayOrder) {
          return a.displayOrder.compareTo(b.displayOrder);
        }
        return a.id.compareTo(b.id);
      });

      return groups;
    } catch (_) {
      return [];
    }
  }

  // ── Menu groups (migration 0052) ───────────────────────────────────────────

  /// Id of the single active group, or null if none is active.
  Future<int?> _activeMenuGroupId() async {
    final row = await _client
        .from('menu_group')
        .select('id')
        .eq('is_active', 1)
        .limit(1)
        .maybeSingle();
    return row == null ? null : (row['id'] as num).toInt();
  }

  @override
  Future<List<MenuGroupModel>> getMenuGroups() async {
    final response =
        await _client.from('menu_group').select().order('sort_order').order('name');
    return (response as List)
        .map((row) => MenuGroupModel.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  @override
  Future<MenuGroupModel> createMenuGroup(String name) async {
    final row = await _client
        .from('menu_group')
        .insert({'name': name})
        .select()
        .single();
    return MenuGroupModel.fromJson(Map<String, dynamic>.from(row));
  }

  @override
  Future<void> renameMenuGroup(int id, String name) async {
    await _client.from('menu_group').update({'name': name}).eq('id', id);
  }

  @override
  Future<void> deleteMenuGroup(int id) async {
    // menu_group_item rows cascade via the FK (migration 0052).
    await _client.from('menu_group').delete().eq('id', id);
  }

  @override
  Future<void> setActiveMenuGroup(int id) async {
    // Two writes (no transaction API here): clear the current active row first so
    // the partial unique index `uq_menu_group_active` never sees two actives.
    await _client.from('menu_group').update({'is_active': 0}).eq('is_active', 1);
    await _client.from('menu_group').update({'is_active': 1}).eq('id', id);
  }

  @override
  Future<Map<String, bool>> getMenuGroupItems(int id) async {
    final response =
        await _client.from('menu_group_item').select('barcode, enabled').eq('group_id', id);
    return {
      for (final row in (response as List))
        (row['barcode'] as String): ((row['enabled'] as num?)?.toInt() ?? 0) == 1,
    };
  }

  @override
  Future<void> setMenuGroupItems(int id, Map<String, bool> updates) async {
    if (updates.isEmpty) return;
    final rows = [
      for (final e in updates.entries)
        {'group_id': id, 'barcode': e.key, 'enabled': e.value ? 1 : 0},
    ];
    await _client.from('menu_group_item').upsert(rows, onConflict: 'group_id,barcode');
  }
}
