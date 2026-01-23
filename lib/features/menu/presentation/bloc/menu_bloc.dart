import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/datasources/menu_supabase_datasource.dart';
import '../../data/models/department_model.dart';
import '../../data/models/category_model.dart';
import '../../data/models/item_model.dart';

part 'menu_event.dart';
part 'menu_state.dart';

class MenuBloc extends Bloc<MenuEvent, MenuState> {
  final MenuSupabaseDataSource _menuDataSource;

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

      var categories = results[1] as List<CategoryModel>;

      // Filter by isAvailableInWebTable
      categories = categories.where((c) => c.isAvailableInWebTable == true).toList();

      // Sort by orderingIndex with nulls last, then by name
      categories.sort((a, b) {
        if (a.orderingIndex == null && b.orderingIndex == null) {
          return a.name.compareTo(b.name);
        }
        if (a.orderingIndex == null) return 1;
        if (b.orderingIndex == null) return -1;

        final result = a.orderingIndex!.compareTo(b.orderingIndex!);
        if (result == 0) {
          return a.name.compareTo(b.name);
        }
        return result;
      });

      int? defaultCatId;
      if (categories.isNotEmpty) {
        defaultCatId = categories.first.categoryId;
      }

      emit(
        MenuLoaded(
          departments: results[0] as List<DepartmentModel>,
          categories: categories,
          items: results[2] as List<ItemModel>,
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
