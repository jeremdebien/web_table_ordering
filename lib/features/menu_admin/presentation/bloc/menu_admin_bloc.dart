import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../menu/data/datasources/menu_data_source.dart';
import '../../../menu/data/models/department_model.dart';
import '../../../menu/data/models/category_model.dart';
import '../../../menu/data/models/item_model.dart';

part 'menu_admin_event.dart';
part 'menu_admin_state.dart';

/// Drives the staff menu-curation screen: loads every orderable item and lets
/// staff stage which ones appear on the customer-facing web menu
/// (`item.is_available_in_web_table`).
///
/// Edits are **staged locally** (a pending map of barcode → desired visibility)
/// for a smooth, instant UI, then written to the consolidator in one batch when
/// the user saves. Discard drops all staged edits.
class MenuAdminBloc extends Bloc<MenuAdminEvent, MenuAdminState> {
  final MenuDataSource _menuDataSource;

  MenuAdminBloc(this._menuDataSource) : super(const MenuAdminInitial()) {
    on<LoadCuration>(_onLoad);
    on<ToggleItemVisibility>(_onToggleItem);
    on<ToggleGroupVisibility>(_onToggleGroup);
    on<SearchChanged>(_onSearch);
    on<SaveChanges>(_onSave);
    on<DiscardChanges>(_onDiscard);
  }

  Future<void> _onLoad(LoadCuration event, Emitter<MenuAdminState> emit) async {
    emit(const MenuAdminLoading());
    try {
      final results = await Future.wait([
        _menuDataSource.getDepartments(),
        _menuDataSource.getCategories(),
        _menuDataSource.getAllItemsForCuration(),
      ]);

      emit(
        MenuAdminLoaded(
          departments: results[0] as List<DepartmentModel>,
          categories: results[1] as List<CategoryModel>,
          items: results[2] as List<ItemModel>,
        ),
      );
    } catch (e) {
      emit(MenuAdminError(e.toString()));
    }
  }

  void _onToggleItem(ToggleItemVisibility event, Emitter<MenuAdminState> emit) {
    final current = state;
    if (current is! MenuAdminLoaded || current.isSaving) return;
    emit(current.stage({event.barcode: event.visible}));
  }

  void _onToggleGroup(ToggleGroupVisibility event, Emitter<MenuAdminState> emit) {
    final current = state;
    if (current is! MenuAdminLoaded || current.isSaving) return;

    final updates = {
      for (final i in current.items)
        if (i.categoryId == event.categoryId && i.barcode.isNotEmpty)
          i.barcode: event.visible,
    };
    if (updates.isEmpty) return;
    emit(current.stage(updates));
  }

  void _onSearch(SearchChanged event, Emitter<MenuAdminState> emit) {
    final current = state;
    if (current is MenuAdminLoaded) {
      emit(current.copyWith(query: event.query));
    }
  }

  Future<void> _onSave(SaveChanges event, Emitter<MenuAdminState> emit) async {
    final current = state;
    if (current is! MenuAdminLoaded || current.pending.isEmpty || current.isSaving) {
      return;
    }

    emit(current.copyWith(isSaving: true, clearError: true));

    final entries = current.pending.entries.toList();
    final failed = <String, bool>{};
    for (final e in entries) {
      try {
        await _menuDataSource.setItemWebVisibility(e.key, e.value);
      } catch (_) {
        failed[e.key] = e.value;
      }
    }

    final s = state;
    if (s is! MenuAdminLoaded) return;

    // Commit successful writes into the base list; keep failures staged.
    final committed = {
      for (final e in entries)
        if (!failed.containsKey(e.key)) e.key: e.value,
    };
    final newItems = s.items
        .map((i) => committed.containsKey(i.barcode)
            ? i.copyWith(isAvailableInWebTable: committed[i.barcode])
            : i)
        .toList();

    emit(s.copyWith(
      items: newItems,
      pending: failed,
      isSaving: false,
      errorMessage: failed.isEmpty ? null : 'Some items could not be saved. Please retry.',
      clearError: failed.isEmpty,
    ));
  }

  void _onDiscard(DiscardChanges event, Emitter<MenuAdminState> emit) {
    final current = state;
    if (current is MenuAdminLoaded) {
      emit(current.copyWith(pending: const {}, clearError: true));
    }
  }
}
