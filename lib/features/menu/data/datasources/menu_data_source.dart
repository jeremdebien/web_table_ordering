import '../models/department_model.dart';
import '../models/category_model.dart';
import '../models/item_model.dart';

/// Read contract for the menu catalog, implemented per app mode.
abstract class MenuDataSource {
  Future<List<DepartmentModel>> getDepartments();
  Future<List<CategoryModel>> getCategories({int? departmentId});
  Future<List<ItemModel>> getItems({int? categoryId});
  String getItemImageUrl(String imagePath);
}
