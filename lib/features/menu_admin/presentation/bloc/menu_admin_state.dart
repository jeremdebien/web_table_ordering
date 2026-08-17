part of 'menu_admin_bloc.dart';

abstract class MenuAdminState extends Equatable {
  const MenuAdminState();

  @override
  List<Object?> get props => [];
}

class MenuAdminInitial extends MenuAdminState {
  const MenuAdminInitial();
}

class MenuAdminLoading extends MenuAdminState {
  const MenuAdminLoading();
}

class MenuAdminError extends MenuAdminState {
  final String message;

  const MenuAdminError(this.message);

  @override
  List<Object?> get props => [message];
}

class MenuAdminLoaded extends MenuAdminState {
  /// Last-saved data (source of truth for original visibility).
  final List<DepartmentModel> departments;
  final List<CategoryModel> categories;
  final List<ItemModel> items;

  /// Staged, unsaved visibility overrides (barcode → desired value). Only holds
  /// entries that differ from the saved value in [items].
  final Map<String, bool> pending;

  /// Client-side search text (matches item name/barcode).
  final String query;

  /// A save batch is in flight.
  final bool isSaving;

  /// One-shot error banner text; cleared on the next successful action.
  final String? errorMessage;

  const MenuAdminLoaded({
    required this.departments,
    required this.categories,
    required this.items,
    this.pending = const {},
    this.query = '',
    this.isSaving = false,
    this.errorMessage,
  });

  bool get isDirty => pending.isNotEmpty;
  int get dirtyCount => pending.length;

  /// Effective (possibly staged) visibility for [item].
  bool visibilityOf(ItemModel item) => pending[item.barcode] ?? item.isAvailableInWebTable;

  MenuAdminLoaded copyWith({
    List<ItemModel>? items,
    Map<String, bool>? pending,
    String? query,
    bool? isSaving,
    String? errorMessage,
    bool clearError = false,
  }) {
    return MenuAdminLoaded(
      departments: departments,
      categories: categories,
      items: items ?? this.items,
      pending: pending ?? this.pending,
      query: query ?? this.query,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  /// Merges [updates] into the staged map, dropping any entry that matches the
  /// last-saved value (so toggling back to the original clears the dirty flag).
  MenuAdminLoaded stage(Map<String, bool> updates) {
    final base = {for (final i in items) i.barcode: i.isAvailableInWebTable};
    final next = Map<String, bool>.from(pending);
    updates.forEach((barcode, visible) {
      if (base[barcode] == visible) {
        next.remove(barcode);
      } else {
        next[barcode] = visible;
      }
    });
    return copyWith(pending: next, clearError: true);
  }

  @override
  List<Object?> get props => [departments, categories, items, pending, query, isSaving, errorMessage];
}
