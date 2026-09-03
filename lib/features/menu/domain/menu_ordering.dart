import '../data/models/department_model.dart';
import '../data/models/category_model.dart';
import '../data/models/item_model.dart';

/// Shared sort logic for the menu hierarchy so every surface — the customer menu
/// ([MenuBloc]) and the staff curation screen ([MenuAdminPage]) — orders
/// Department → Category → Item identically.
///
/// The defined position wins: departments and categories by `orderingIndex`,
/// items by `buttonIndex`. A missing (null) position always sorts **last**, and
/// ties fall back to a stable id then name comparison.
class MenuOrdering {
  const MenuOrdering._();

  /// Departments by `orderingIndex` (nulls last), then id, then name.
  /// Null departments (unknown/unmapped) sort last.
  static int compareDepartments(DepartmentModel? a, DepartmentModel? b) {
    if (identical(a, b)) return 0;
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;

    final ai = a.orderingIndex;
    final bi = b.orderingIndex;
    if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
    if (ai == null && bi != null) return 1;
    if (ai != null && bi == null) return -1;

    final aid = a.deptId ?? a.id;
    final bid = b.deptId ?? b.id;
    if (aid != bid) return aid.compareTo(bid);
    return a.name.compareTo(b.name);
  }

  /// Categories by `orderingIndex` (nulls last), then id, then name.
  /// Compares only the categories themselves — callers that need
  /// department-then-category ordering should bucket by department first (or use
  /// [compareCategoriesHierarchically]).
  static int compareCategories(CategoryModel a, CategoryModel b) {
    final ai = a.orderingIndex;
    final bi = b.orderingIndex;
    if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
    if (ai == null && bi != null) return 1;
    if (ai != null && bi == null) return -1;

    final aid = a.categoryId ?? a.id;
    final bid = b.categoryId ?? b.id;
    if (aid != bid) return aid.compareTo(bid);
    return a.name.compareTo(b.name);
  }

  /// Categories ordered first by their parent department, then by the category
  /// itself. [deptById] resolves a category's `departmentId` to its department.
  static int compareCategoriesHierarchically(
    CategoryModel a,
    CategoryModel b,
    Map<int, DepartmentModel> deptById,
  ) {
    if (a.departmentId != b.departmentId) {
      final deptComp =
          compareDepartments(deptById[a.departmentId], deptById[b.departmentId]);
      if (deptComp != 0) return deptComp;
    }
    return compareCategories(a, b);
  }

  /// Items by `buttonIndex` (nulls last), then id, then name.
  static int compareItems(ItemModel a, ItemModel b) {
    final ai = a.buttonIndex;
    final bi = b.buttonIndex;
    if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
    if (ai == null && bi != null) return 1;
    if (ai != null && bi == null) return -1;

    final idComp = a.id.compareTo(b.id);
    if (idComp != 0) return idComp;
    return a.name.compareTo(b.name);
  }
}
