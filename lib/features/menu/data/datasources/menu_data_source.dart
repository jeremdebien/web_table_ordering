import '../../domain/availability_snapshot.dart';
import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import '../models/instruction_group_model.dart';
import '../models/menu_group_model.dart';
import '../models/option_group_model.dart';

/// Read contract for the menu catalog, implemented per app mode.
abstract class MenuDataSource {
  Future<List<DepartmentModel>> getDepartments();
  Future<List<CategoryModel>> getCategories({int? departmentId});
  /// [includeStaffOnly]: also return `is_staff_only` items (staff logged in).
  Future<List<ItemModel>> getItems({int? categoryId, bool includeStaffOnly = false});
  String getItemImageUrl(String imagePath);

  // ── POS item availability ──────────────────────────────────────────────────
  // Sold-out (`item.is_sold_out`) rides on [ItemModel]; hidden items
  // (`item.is_hidden`) are dropped by [getItems]; schedule rules come from here.

  /// Active `item_availability` rules + active holidays (empty if none).
  Future<AvailabilitySnapshot> getAvailabilitySnapshot();

  /// Current rows for [barcodes] that are still enabled and not hidden, keyed
  /// by barcode. A barcode missing from the result can't be ordered any more.
  Future<Map<String, ItemModel>> getOrderableItemsByBarcodes(List<String> barcodes);

  /// Fires whenever an `item` row changes (sold out, hidden, disabled...).
  Stream<void> itemChanges();

  /// All orderable items (`item_status = 1`) regardless of web visibility, for
  /// the staff menu-curation screen — so items currently hidden from the web
  /// menu still render (unchecked) and can be re-enabled.
  Future<List<ItemModel>> getAllItemsForCuration();

  /// Sets whether an item appears on the customer-facing web menu
  /// (`is_available_in_web_table`), keyed by barcode.
  Future<void> setItemWebVisibility(String barcode, bool visible);

  /// User-defined special-instruction questions for an item (empty if none).
  /// Fetches Global + Category + Item level questions sorted by priority.
  Future<List<InstructionGroup>> getItemInstructions(String barcode, {int? categoryId});

  /// POS product-customization option groups assigned to an item (empty if
  /// none), in the POS picker order. Local mode only.
  Future<List<OptionGroup>> getItemCustomization(String barcode);

  // ── Menu groups (batch item-availability presets, migration 0052) ──────────
  // Named menu configurations staff can switch between. The active group is the
  // source of truth for the customer web menu (live-override); with no active
  // group, [getItems] falls back to `is_available_in_web_table`.

  /// All menu groups, ordered by sort order then name.
  Future<List<MenuGroupModel>> getMenuGroups();

  /// Creates a new (inactive) group and returns the persisted row.
  Future<MenuGroupModel> createMenuGroup(String name);

  /// Renames a group.
  Future<void> renameMenuGroup(int id, String name);

  /// Deletes a group; its `menu_group_item` rows cascade away.
  Future<void> deleteMenuGroup(int id);

  /// Makes [id] the single active group (clears any other active flag).
  Future<void> setActiveMenuGroup(int id);

  /// A group's per-item config as `barcode → enabled`.
  Future<Map<String, bool>> getMenuGroupItems(int id);

  /// Upserts a batch of `barcode → enabled` entries into a group's config.
  Future<void> setMenuGroupItems(int id, Map<String, bool> updates);
}
