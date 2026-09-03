import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/datasources/menu_data_source.dart';
import '../../data/models/department_model.dart';
import '../../data/models/category_model.dart';
import '../../data/models/item_model.dart';
import '../../domain/menu_ordering.dart';

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

      // Sort categories hierarchically: by parent Department order, then by Category order.
      categories.sort(
        (a, b) => MenuOrdering.compareCategoriesHierarchically(a, b, deptById),
      );

      final sortedItems =
          List<ItemModel>.from(items)..sort(MenuOrdering.compareItems);

      // Hide categories that have no available items (e.g. every item disabled by
      // the active menu group), so empty category pills never render.
      final categoryIdsWithItems = sortedItems.map((i) => i.categoryId).toSet();
      categories = categories
          .where((c) => categoryIdsWithItems.contains(c.categoryId ?? c.id))
          .toList();

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
