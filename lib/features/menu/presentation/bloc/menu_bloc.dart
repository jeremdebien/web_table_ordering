import 'package:flutter_bloc/flutter_bloc.dart';
import 'menu_event.dart';
import 'menu_state.dart';
import '../../data/datasources/menu_supabase_datasource.dart';

class MenuBloc extends Bloc<MenuEvent, MenuState> {
  final MenuSupabaseDataSource _menuDataSource;

  MenuBloc(this._menuDataSource) : super(const MenuState()) {
    on<GetDepartments>(_onGetDepartments);
    on<GetCategories>(_onGetCategories);
    on<GetItems>(_onGetItems);
  }

  Future<void> _onGetDepartments(GetDepartments event, Emitter<MenuState> emit) async {
    emit(state.copyWith(status: MenuStatus.loading));
    try {
      final departments = await _menuDataSource.getDepartments();
      emit(state.copyWith(status: MenuStatus.success, departments: departments));
    } catch (e) {
      emit(state.copyWith(status: MenuStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _onGetCategories(GetCategories event, Emitter<MenuState> emit) async {
    emit(state.copyWith(status: MenuStatus.loading, selectedDepartmentId: event.departmentId));
    try {
      final categories = await _menuDataSource.getCategories(departmentId: event.departmentId);
      emit(
        state.copyWith(
          status: MenuStatus.success,
          categories: categories,
          // Optional: clear items when category changes?
          // Or keep them until new items load. Let's keep them for now.
        ),
      );
    } catch (e) {
      emit(state.copyWith(status: MenuStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _onGetItems(GetItems event, Emitter<MenuState> emit) async {
    emit(state.copyWith(status: MenuStatus.loading, selectedCategoryId: event.categoryId));
    try {
      final items = await _menuDataSource.getItems(categoryId: event.categoryId);
      emit(state.copyWith(status: MenuStatus.success, items: items));
    } catch (e) {
      emit(state.copyWith(status: MenuStatus.failure, errorMessage: e.toString()));
    }
  }
}
