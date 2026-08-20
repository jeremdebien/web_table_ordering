import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';
import '../models/instruction_group_model.dart';

/// Read contract for the menu catalog, implemented per app mode.
abstract class MenuDataSource {
  Future<List<DepartmentModel>> getDepartments();
  Future<List<CategoryModel>> getCategories({int? departmentId});
  Future<List<ItemModel>> getItems({int? categoryId});
  String getItemImageUrl(String imagePath);

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
}
