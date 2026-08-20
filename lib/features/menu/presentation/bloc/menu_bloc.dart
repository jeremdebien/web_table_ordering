import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/datasources/menu_data_source.dart';
import '../../data/models/department_model.dart';
import '../../data/models/category_model.dart';
import '../../data/models/item_model.dart';

part 'menu_event.dart';
part 'menu_state.dart';

class MenuBloc extends Bloc<MenuEvent, MenuState> {
  final MenuDataSource _menuDataSource;

  MenuBloc(this._menuDataSource) : super(const MenuInitial()) {
    on<LoadMenu>(_onLoadMenu);
    on<SelectDepartment>(_onSelectDepartment);
    on<SelectCategory>(_onSelectCategory);
  }

  Future<void> _onLoadMenu(LoadMenu event, Emitter<MenuState> emit) async {
    emit(const MenuLoading());
    try {
      final results = await Future.wait([
        _menuDataSource.getDepartments(),
        _menuDataSource.getCategories(),
        _menuDataSource.getItems(),
      ]);

      final departments = results[0] as List<DepartmentModel>;
      var categories = results[1] as List<CategoryModel>;
      final items = results[2] as List<ItemModel>;

      // Filter by isAvailableInWebTable
      categories = categories.where((c) => c.isAvailableInWebTable == true).toList();

      // Build department lookup map for hierarchical sorting
      final Map<int, DepartmentModel> deptById = {
        for (final d in departments) ...{
          d.id: d,
          if (d.deptId != null) d.deptId!: d,
        }
      };

      int compareDepartments(DepartmentModel? a, DepartmentModel? b) {
        if (identical(a, b)) return 0;
        if (a == null && b == null) return 0;
        if (a == null) return 1; // unset/missing department sorts last
        if (b == null) return -1;

        final ai = a.orderingIndex;
        final bi = b.orderingIndex;
        if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
        if (ai == null && bi != null) return 1; // unset ordering_index sorts last
        if (ai != null && bi == null) return -1;

        final aid = a.deptId ?? a.id;
        final bid = b.deptId ?? b.id;
        if (aid != bid) return aid.compareTo(bid);
        return a.name.compareTo(b.name);
      }

      int compareCategoriesWithinDept(CategoryModel a, CategoryModel b) {
        final ai = a.orderingIndex;
        final bi = b.orderingIndex;
        if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
        if (ai == null && bi != null) return 1; // unset ordering_index sorts last
        if (ai != null && bi == null) return -1;

        final aid = a.categoryId ?? a.id;
        final bid = b.categoryId ?? b.id;
        if (aid != bid) return aid.compareTo(bid);
        return a.name.compareTo(b.name);
      }

      // Sort categories hierarchically: by parent Department order, then by Category order
      categories.sort((a, b) {
        if (a.departmentId != b.departmentId) {
          final deptA = deptById[a.departmentId];
          final deptB = deptById[b.departmentId];
          final deptComp = compareDepartments(deptA, deptB);
          if (deptComp != 0) return deptComp;
        }
        return compareCategoriesWithinDept(a, b);
      });

      int compareItemsByButtonIndex(ItemModel a, ItemModel b) {
        final ai = a.buttonIndex;
        final bi = b.buttonIndex;
        if (ai != null && bi != null && ai != bi) return ai.compareTo(bi);
        if (ai == null && bi != null) return 1; // unset positions sort last
        if (ai != null && bi == null) return -1;
        final idComp = a.id.compareTo(b.id);
        if (idComp != 0) return idComp;
        return a.name.compareTo(b.name);
      }

      final sortedItems = List<ItemModel>.from(items)..sort(compareItemsByButtonIndex);

      int? defaultCatId;
      if (categories.isNotEmpty) {
        defaultCatId = categories.first.categoryId ?? categories.first.id;
      }

      emit(
        MenuLoaded(
          departments: departments,
          categories: categories,
          items: sortedItems,
          selectedCategoryId: defaultCatId,
        ),
      );
    } catch (e) {
      emit(MenuError(e.toString()));
    }
  }

  Future<void> _onSelectDepartment(SelectDepartment event, Emitter<MenuState> emit) async {
    final currentState = state;
    if (currentState is MenuLoaded) {
      emit(currentState.copyWith(selectedDepartmentId: event.departmentId));
    }
  }

  Future<void> _onSelectCategory(SelectCategory event, Emitter<MenuState> emit) async {
    final currentState = state;
    if (currentState is MenuLoaded) {
      emit(currentState.copyWith(selectedCategoryId: event.categoryId));
    }
  }
}
