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
  /// entries that differ from the saved value (the per-item flag, or the edited
  /// group's config when [editingGroupId] is set).
  final Map<String, bool> pending;

  /// Client-side search text (matches item name/barcode).
  final String query;

  /// A save batch is in flight.
  final bool isSaving;

  /// One-shot error banner text; cleared on the next successful action.
  final String? errorMessage;

  /// All saved menu groups.
  final List<MenuGroupModel> groups;

  /// The group whose config the checkboxes currently represent, or null when
  /// editing the legacy per-item `is_available_in_web_table` flags directly.
  final int? editingGroupId;

  /// Last-saved config (`barcode → enabled`) of the group being edited. Empty
  /// when [editingGroupId] is null. Absence of a barcode ⇒ disabled.
  final Map<String, bool> groupConfig;

  const MenuAdminLoaded({
    required this.departments,
    required this.categories,
    required this.items,
    this.pending = const {},
    this.query = '',
    this.isSaving = false,
    this.errorMessage,
    this.groups = const [],
    this.editingGroupId,
    this.groupConfig = const {},
  });

  bool get isDirty => pending.isNotEmpty;
  int get dirtyCount => pending.length;

  /// The currently active group (drives the customer web menu), or null.
  MenuGroupModel? get activeGroup {
    for (final g in groups) {
      if (g.isActive) return g;
    }
    return null;
  }

  /// The group being edited, or null.
  MenuGroupModel? get editingGroup {
    if (editingGroupId == null) return null;
    for (final g in groups) {
      if (g.id == editingGroupId) return g;
    }
    return null;
  }

  /// Last-saved visibility for [barcode]: the edited group's config when a group
  /// is being edited, otherwise the per-item flag.
  bool _savedVisibility(String barcode, bool itemFlag) =>
      editingGroupId != null ? (groupConfig[barcode] ?? false) : itemFlag;

  /// Effective (possibly staged) visibility for [item].
  bool visibilityOf(ItemModel item) =>
      pending[item.barcode] ?? _savedVisibility(item.barcode, item.isAvailableInWebTable);

  MenuAdminLoaded copyWith({
    List<ItemModel>? items,
    Map<String, bool>? pending,
    String? query,
    bool? isSaving,
    String? errorMessage,
    bool clearError = false,
    List<MenuGroupModel>? groups,
    int? editingGroupId,
    Map<String, bool>? groupConfig,
    bool clearEditing = false,
  }) {
    return MenuAdminLoaded(
      departments: departments,
      categories: categories,
      items: items ?? this.items,
      pending: pending ?? this.pending,
      query: query ?? this.query,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      groups: groups ?? this.groups,
      editingGroupId: clearEditing ? null : (editingGroupId ?? this.editingGroupId),
      groupConfig: clearEditing ? const {} : (groupConfig ?? this.groupConfig),
    );
  }

  /// Merges [updates] into the staged map, dropping any entry that matches the
  /// last-saved value (so toggling back to the original clears the dirty flag).
  MenuAdminLoaded stage(Map<String, bool> updates) {
    // Last-saved value per barcode: the edited group's config (absence ⇒
    // disabled) when a group is being edited, otherwise the per-item flag.
    final base = editingGroupId != null
        ? {for (final i in items) i.barcode: groupConfig[i.barcode] ?? false}
        : {for (final i in items) i.barcode: i.isAvailableInWebTable};
    final next = Map<String, bool>.from(pending);
    updates.forEach((barcode, visible) {
      if ((base[barcode] ?? (editingGroupId != null ? false : true)) == visible) {
        next.remove(barcode);
      } else {
        next[barcode] = visible;
      }
    });
    return copyWith(pending: next, clearError: true);
  }

  @override
  List<Object?> get props =>
      [departments, categories, items, pending, query, isSaving, errorMessage, groups, editingGroupId, groupConfig];
}
