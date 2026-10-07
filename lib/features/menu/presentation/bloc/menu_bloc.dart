import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/datasources/menu_data_source.dart';
import '../../data/models/department_model.dart';
import '../../data/models/category_model.dart';
import '../../data/models/item_model.dart';
import '../../domain/availability_snapshot.dart';
import '../../domain/menu_ordering.dart';

part 'menu_event.dart';
part 'menu_state.dart';

class MenuBloc extends Bloc<MenuEvent, MenuState> {
  final MenuDataSource _menuDataSource;
  // Include staff-only items in every load (see SetStaffMode).
  bool _isStaff = false;

  // POS availability: a realtime ping on `item` changes (debounced, since a POS
  // batch edit fires one per row) and a minute tick for schedule windows.
  StreamSubscription<void>? _itemChangesSub;
  Timer? _itemChangesDebounce;
  Timer? _availabilityTicker;

  MenuBloc(this._menuDataSource) : super(const MenuInitial()) {
    on<LoadMenu>(_onLoadMenu);
    on<SelectDepartment>(_onSelectDepartment);
    on<SelectCategory>(_onSelectCategory);
    on<SetStaffMode>(_onSetStaffMode);
    on<AvailabilityTick>(_onAvailabilityTick);
    on<ItemsChanged>(_onItemsChanged);

    _itemChangesSub = _menuDataSource.itemChanges().listen((_) {
      _itemChangesDebounce?.cancel();
      _itemChangesDebounce = Timer(const Duration(seconds: 1), () => add(const ItemsChanged()));
    });
    _availabilityTicker = Timer.periodic(const Duration(minutes: 1), (_) => add(const AvailabilityTick()));
  }

  /// Minute precision: schedule rules are HH:mm, so a coarser clock keeps the
  /// tick from re-emitting identical states.
  static DateTime _nowToMinute() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, n.hour, n.minute);
  }

  Future<void> _onSetStaffMode(SetStaffMode event, Emitter<MenuState> emit) async {
    if (event.isStaff == _isStaff) return;
    _isStaff = event.isStaff;
    await _onLoadMenu(LoadMenu(), emit);
  }

  Future<void> _onLoadMenu(LoadMenu event, Emitter<MenuState> emit) async {
    emit(const MenuLoading());
    try {
      emit(await _fetchMenu());
    } catch (e) {
      emit(MenuError(e.toString()));
    }
  }

  /// Background refresh after a POS item change: no loading flash, and the
  /// guest stays on the category they were browsing if it still exists.
  Future<void> _onItemsChanged(ItemsChanged event, Emitter<MenuState> emit) async {
    final current = state;
    if (current is! MenuLoaded) return;
    try {
      final fresh = await _fetchMenu();
      final keep = current.selectedCategoryId;
      final stillThere = keep != null && fresh.categories.any((c) => (c.categoryId ?? c.id) == keep);
      emit(fresh.copyWith(
        selectedCategoryId: stillThere ? keep : null,
        selectedDepartmentId: current.selectedDepartmentId,
      ));
    } catch (_) {
      // Keep showing the last good menu; the next change or reload retries.
    }
  }

  void _onAvailabilityTick(AvailabilityTick event, Emitter<MenuState> emit) {
    final current = state;
    if (current is MenuLoaded) emit(current.copyWith(now: _nowToMinute()));
  }

  Future<MenuLoaded> _fetchMenu() async {
    final results = await Future.wait([
      _menuDataSource.getDepartments(),
      _menuDataSource.getCategories(),
      _menuDataSource.getItems(includeStaffOnly: _isStaff),
      _menuDataSource.getAvailabilitySnapshot(),
    ]);

    final departments = results[0] as List<DepartmentModel>;
    var categories = results[1] as List<CategoryModel>;
    final items = results[2] as List<ItemModel>;
    final availability = results[3] as AvailabilitySnapshot;

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
    // the active menu group), so empty category pills never render. Sold-out
    // and off-schedule items still count: they are listed, just greyed out.
    final categoryIdsWithItems = sortedItems.map((i) => i.categoryId).toSet();
    categories = categories
        .where((c) => categoryIdsWithItems.contains(c.categoryId ?? c.id))
        .toList();

    int? defaultCatId;
    if (categories.isNotEmpty) {
      defaultCatId = categories.first.categoryId ?? categories.first.id;
    }

    return MenuLoaded(
      departments: departments,
      categories: categories,
      items: sortedItems,
      selectedCategoryId: defaultCatId,
      availability: availability,
      now: _nowToMinute(),
    );
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

  @override
  Future<void> close() {
    _itemChangesSub?.cancel();
    _itemChangesDebounce?.cancel();
    _availabilityTicker?.cancel();
    return super.close();
  }
}
