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

      final categories = results[1] as List<CategoryModel>;
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
