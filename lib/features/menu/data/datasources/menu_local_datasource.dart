import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/config/app_config.dart';
import '../../domain/availability_snapshot.dart';
import '../../domain/item_availability_rule.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import '../models/instruction_group_model.dart';
import '../models/instruction_choice_model.dart';
import '../models/menu_group_model.dart';
import '../models/option_group_model.dart';
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

  // POS "hidden" items (`item.is_hidden`, INTEGER) never reach the web menu.
  // NULL counts as not hidden.
  static const String _notHidden = 'is_hidden.is.null,is_hidden.eq.0';

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
  Future<List<ItemModel>> getItems({int? categoryId, bool includeStaffOnly = false}) async {
    // Live-override resolution (migration 0052): if a menu group is active, it is
    // the source of truth -- show only its enabled barcodes. With NO active
    // group, fall back to the per-item `is_available_in_web_table` flag
    // (migration 0047) so the menu keeps working before any group is created.
    final activeId = await _activeMenuGroupId();

    var query = _client.from('item').select().eq('item_status', 1).or(_notHidden);

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

    // Curation alone decides what customers see; a staff-only item (migration
    // 0080) that is ticked in curation is public too.
    final response = await query.order('item_desc');
    final items = (response as List).map((row) => _mapItemRow(row)).toList();
    if (!includeStaffOnly) return items;

    // Staff logged in: add every staff-only item, regardless of the active
    // menu group or the per-item web flag.
    var staffQuery = _client.from('item').select().eq('item_status', 1).or(_notHidden).eq('is_staff_only', 1);
    if (categoryId != null) {
      staffQuery = staffQuery.eq('category', categoryId);
    }
    final staffRows = await staffQuery.order('item_desc');
    final seen = {for (final i in items) i.barcode};
    return [
      ...items,
      ...(staffRows as List).map((row) => _mapItemRow(row)).where((i) => seen.add(i.barcode)),
    ];
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
      'is_staff_only': row['is_staff_only'],
      'is_sold_out': _flag(row['is_sold_out']),
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
  Future<AvailabilitySnapshot> getAvailabilitySnapshot() async {
    final results = await Future.wait([
      _client.from('item_availability').select().eq('is_active', 1),
      _client.from('holidays').select('holiday_date').eq('is_active', 1),
    ]);
    final rules = (results[0] as List)
        .map((row) => ItemAvailabilityRule.fromJson(row as Map<String, dynamic>))
        .toList();
    final holidays = [for (final row in results[1] as List) row['holiday_date'] as String];
    return AvailabilitySnapshot.fromRules(rules, holidays);
  }

  @override
  Future<Map<String, ItemModel>> getOrderableItemsByBarcodes(List<String> barcodes) async {
    if (barcodes.isEmpty) return {};
    final response = await _client
        .from('item')
        .select()
        .eq('item_status', 1)
        .or(_notHidden)
        .inFilter('barcode', barcodes);
    return {for (final row in response as List) row['barcode'] as String: _mapItemRow(row)};
  }

  @override
  Stream<void> itemChanges() {
    // A bare change ping on the realtime-published `item` table (0000-0025);
    // listeners re-fetch what they need. Lighter than `.stream()`, which would
    // resend every item row on each change.
    late final StreamController<void> controller;
    RealtimeChannel? channel;
    controller = StreamController<void>(
      onListen: () {
        channel = _client
            .channel('web_item_changes_${DateTime.now().microsecondsSinceEpoch}')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'item',
              callback: (_) => controller.add(null),
            )
            .subscribe();
      },
      onCancel: () async {
        final c = channel;
        channel = null;
        if (c != null) await _client.removeChannel(c);
      },
    );
    return controller.stream;
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

  /// Ports kwikpos_lite `CustomizationHelper.getAllAssignedOptionValuesByBarcode`
  /// with batched `in()` reads: assignments → (preset →) groups → values (by
  /// group or value preset) → per-product overrides, plus the value items for
  /// names/prices. Values whose item is inactive are dropped (sold out).
  @override
  Future<List<OptionGroup>> getItemCustomization(String barcode) async {
    try {
      final assignmentRows = List<Map<String, dynamic>>.from(await _client
          .from('product_option_group_assignments')
          .select('group_preset_id, option_group_id, display_order')
          .eq('barcode', barcode)
          // supabase-dart orders DESC by default — the POS reads ASC.
          .order('display_order', ascending: true)
          // sqlite breaks display_order ties by rowid; mirror that.
          .order('id', ascending: true));
      if (assignmentRows.isEmpty) return [];

      int? asInt(dynamic v) => (v as num?)?.toInt();

      final presetIds = assignmentRows.map((a) => asInt(a['group_preset_id'])).whereType<int>().toSet().toList();
      final presetGroupRows = presetIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _client
              .from('option_group_preset_groups')
              .select('group_preset_id, option_group_id, display_order')
              .inFilter('group_preset_id', presetIds)
              .order('display_order', ascending: true)
              .order('id', ascending: true));

      // Group ids in display order: assignment order, then preset member order.
      final orderedGroupIds = <int>[];
      for (final a in assignmentRows) {
        final presetId = asInt(a['group_preset_id']);
        if (presetId != null) {
          for (final pg in presetGroupRows.where((r) => asInt(r['group_preset_id']) == presetId)) {
            final gid = asInt(pg['option_group_id']);
            if (gid != null && !orderedGroupIds.contains(gid)) orderedGroupIds.add(gid);
          }
        } else {
          final gid = asInt(a['option_group_id']);
          if (gid != null && !orderedGroupIds.contains(gid)) orderedGroupIds.add(gid);
        }
      }
      if (orderedGroupIds.isEmpty) return [];

      final groupRows = List<Map<String, dynamic>>.from(
          await _client.from('option_groups').select().inFilter('id', orderedGroupIds));
      final groupById = {for (final g in groupRows) asInt(g['id'])!: g};

      final valuePresetIds =
          groupRows.map((g) => asInt(g['value_preset_id'])).whereType<int>().toSet().toList();
      final valueFilter = [
        'option_group_id.in.(${orderedGroupIds.join(',')})',
        if (valuePresetIds.isNotEmpty) 'value_preset_id.in.(${valuePresetIds.join(',')})',
      ].join(',');
      final valueRows = List<Map<String, dynamic>>.from(await _client
          .from('option_values')
          .select('id, value_preset_id, option_group_id, alias, barcode, price_delta, quantity, unit, display_order')
          .or(valueFilter));

      final valueBarcodes = valueRows.map((v) => v['barcode'] as String).toSet().toList();
      final itemRows = valueBarcodes.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _client
              .from('item')
              .select('barcode, item_desc, print_desc, price, item_status, image_object')
              .inFilter('barcode', valueBarcodes));
      final itemByBarcode = {
        for (final i in itemRows)
          if (_flag(i['item_status'])) i['barcode'] as String: i,
      };

      // Overrides for the base product AND each size it can switch to, so add-on
      // prices follow the chosen size like the POS's per-size repricing.
      final valueIds = valueRows.map((v) => asInt(v['id'])!).toList();
      final overrideRows = valueIds.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _client
              .from('product_option_value_overrides')
              .select('product_barcode, option_value_id, option_group_id, alias, price_delta')
              .inFilter('product_barcode', {barcode, ...valueBarcodes}.toList())
              .inFilter('option_value_id', valueIds));

      final groups = <OptionGroup>[];
      for (final gid in orderedGroupIds) {
        final g = groupById[gid];
        if (g == null) continue;
        final valuePresetId = asInt(g['value_preset_id']);
        final rows = valueRows.where((v) => valuePresetId != null
            ? asInt(v['value_preset_id']) == valuePresetId
            : asInt(v['option_group_id']) == gid);

        final values = <OptionValue>[];
        for (final v in rows) {
          final item = itemByBarcode[v['barcode']];
          if (item == null) continue; // inactive / missing item → hidden
          final vid = asInt(v['id'])!;
          // Group-specific override wins over the NULL-group fallback row.
          final overrides = <String, ({double? priceDelta, String? alias})>{};
          for (final specific in [false, true]) {
            for (final o in overrideRows.where((o) =>
                asInt(o['option_value_id']) == vid &&
                (specific ? asInt(o['option_group_id']) == gid : o['option_group_id'] == null))) {
              overrides[o['product_barcode'] as String] = (
                priceDelta: (o['price_delta'] as num?)?.toDouble(),
                alias: o['alias'] as String?,
              );
            }
          }
          values.add(OptionValue(
            id: vid,
            barcode: v['barcode'] as String,
            alias: v['alias'] as String?,
            priceDelta: (v['price_delta'] as num?)?.toDouble(),
            quantity: (v['quantity'] as num?)?.toDouble() ?? 1,
            unit: asInt(v['unit']) ?? 1,
            displayOrder: asInt(v['display_order']) ?? 0,
            itemName: (item['item_desc'] as String?) ?? '',
            receiptName: (item['print_desc'] as String?) ?? (item['item_desc'] as String?),
            itemPrice: (item['price'] as num?)?.toDouble() ?? 0,
            imageUrl: item['image_object'] != null
                ? '${AppConfig.imageStoragePath}$_imageBucket/${item['image_object']}'
                : null,
            overridesByProduct: overrides,
          ));
        }
        values.sort((a, b) =>
            a.displayOrder != b.displayOrder ? a.displayOrder.compareTo(b.displayOrder) : a.id.compareTo(b.id));
        if (values.isEmpty) continue;
        groups.add(OptionGroup.fromJson(g, values: values));
      }

      // Keep the POS picker's order (assignment → preset member → value
      // display_order); sizes are not hoisted.
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
