import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../menu/data/datasources/menu_data_source.dart';
import '../../../menu/data/models/department_model.dart';
import '../../../menu/data/models/category_model.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/data/models/menu_group_model.dart';

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
    on<CreateGroup>(_onCreateGroup);
    on<RenameGroup>(_onRenameGroup);
    on<DeleteGroup>(_onDeleteGroup);
    on<SelectActiveGroup>(_onSelectActiveGroup);
    on<EditGroup>(_onEditGroup);
  }

  Future<void> _onLoad(LoadCuration event, Emitter<MenuAdminState> emit) async {
    emit(const MenuAdminLoading());
    try {
      final results = await Future.wait([
        _menuDataSource.getDepartments(),
        _menuDataSource.getCategories(),
        _menuDataSource.getAllItemsForCuration(),
        _menuDataSource.getMenuGroups(),
      ]);

      emit(
        MenuAdminLoaded(
          departments: results[0] as List<DepartmentModel>,
          categories: results[1] as List<CategoryModel>,
          items: results[2] as List<ItemModel>,
          groups: results[3] as List<MenuGroupModel>,
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

    // Editing a menu group: write the whole staged batch in one upsert and, on
    // success, fold it into the group's saved config.
    if (current.editingGroupId != null) {
      final groupId = current.editingGroupId!;
      try {
        await _menuDataSource.setMenuGroupItems(groupId, current.pending);
      } catch (_) {
        final s = state;
        if (s is MenuAdminLoaded) {
          emit(s.copyWith(
            isSaving: false,
            errorMessage: 'Could not save the group. Please retry.',
          ));
        }
        return;
      }
      final s = state;
      if (s is! MenuAdminLoaded) return;
      final newConfig = Map<String, bool>.from(s.groupConfig)..addAll(current.pending);
      emit(s.copyWith(
        groupConfig: newConfig,
        pending: const {},
        isSaving: false,
        clearError: true,
      ));
      return;
    }

    // Legacy per-item flag path.
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

  /// Reloads the group list from the datasource, preserving the rest of state.
  Future<void> _reloadGroups(Emitter<MenuAdminState> emit) async {
    final s = state;
    if (s is! MenuAdminLoaded) return;
    final groups = await _menuDataSource.getMenuGroups();
    emit(s.copyWith(groups: groups));
  }

  Future<void> _onCreateGroup(CreateGroup event, Emitter<MenuAdminState> emit) async {
    final current = state;
    if (current is! MenuAdminLoaded) return;
    final name = event.name.trim();
    if (name.isEmpty) return;
    try {
      final created = await _menuDataSource.createMenuGroup(name);
      await _reloadGroups(emit);
      // Drop straight into editing the new (empty) group.
      add(EditGroup(created.id));
    } catch (_) {
      final s = state;
      if (s is MenuAdminLoaded) {
        emit(s.copyWith(errorMessage: 'Could not create the group.'));
      }
    }
  }

  Future<void> _onRenameGroup(RenameGroup event, Emitter<MenuAdminState> emit) async {
    final current = state;
    if (current is! MenuAdminLoaded) return;
    final name = event.name.trim();
    if (name.isEmpty) return;
    try {
      await _menuDataSource.renameMenuGroup(event.id, name);
      await _reloadGroups(emit);
    } catch (_) {
      final s = state;
      if (s is MenuAdminLoaded) {
        emit(s.copyWith(errorMessage: 'Could not rename the group.'));
      }
    }
  }

  Future<void> _onDeleteGroup(DeleteGroup event, Emitter<MenuAdminState> emit) async {
    final current = state;
    if (current is! MenuAdminLoaded) return;
    try {
      await _menuDataSource.deleteMenuGroup(event.id);
      // If we were editing the deleted group, exit editing (and drop its edits).
      if (current.editingGroupId == event.id) {
        emit(current.copyWith(clearEditing: true, pending: const {}));
      }
      await _reloadGroups(emit);
    } catch (_) {
      final s = state;
      if (s is MenuAdminLoaded) {
        emit(s.copyWith(errorMessage: 'Could not delete the group.'));
      }
    }
  }

  Future<void> _onSelectActiveGroup(
      SelectActiveGroup event, Emitter<MenuAdminState> emit) async {
    final current = state;
    if (current is! MenuAdminLoaded) return;
    try {
      await _menuDataSource.setActiveMenuGroup(event.id);
      await _reloadGroups(emit);
    } catch (_) {
      final s = state;
      if (s is MenuAdminLoaded) {
        emit(s.copyWith(errorMessage: 'Could not set the active group.'));
      }
    }
  }

  Future<void> _onEditGroup(EditGroup event, Emitter<MenuAdminState> emit) async {
    final current = state;
    if (current is! MenuAdminLoaded || current.isSaving) return;

    // Return to editing the legacy per-item flags.
    if (event.id == null) {
      emit(current.copyWith(clearEditing: true, pending: const {}, clearError: true));
      return;
    }

    try {
      final config = await _menuDataSource.getMenuGroupItems(event.id!);
      final s = state;
      if (s is! MenuAdminLoaded) return;
      emit(s.copyWith(
        editingGroupId: event.id,
        groupConfig: config,
        pending: const {},
        clearError: true,
      ));
    } catch (_) {
      final s = state;
      if (s is MenuAdminLoaded) {
        emit(s.copyWith(errorMessage: 'Could not load the group config.'));
      }
    }
  }

  void _onDiscard(DiscardChanges event, Emitter<MenuAdminState> emit) {
    final current = state;
    if (current is MenuAdminLoaded) {
      emit(current.copyWith(pending: const {}, clearError: true));
    }
  }
}
