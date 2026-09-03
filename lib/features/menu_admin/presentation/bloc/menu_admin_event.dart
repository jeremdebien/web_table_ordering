part of 'menu_admin_bloc.dart';

abstract class MenuAdminEvent extends Equatable {
  const MenuAdminEvent();

  @override
  List<Object?> get props => [];
}

/// Load departments, categories, and every orderable item for curation.
class LoadCuration extends MenuAdminEvent {
  const LoadCuration();
}

/// Stage a single item's web-menu visibility (not yet written).
class ToggleItemVisibility extends MenuAdminEvent {
  final String barcode;
  final bool visible;

  const ToggleItemVisibility(this.barcode, this.visible);

  @override
  List<Object?> get props => [barcode, visible];
}

/// Stage every item in a category to the given visibility (select-all).
class ToggleGroupVisibility extends MenuAdminEvent {
  final int categoryId;
  final bool visible;

  const ToggleGroupVisibility(this.categoryId, this.visible);

  @override
  List<Object?> get props => [categoryId, visible];
}

/// Update the client-side search filter.
class SearchChanged extends MenuAdminEvent {
  final String query;

  const SearchChanged(this.query);

  @override
  List<Object?> get props => [query];
}

/// Write all staged changes to the consolidator in one batch.
class SaveChanges extends MenuAdminEvent {
  const SaveChanges();
}

/// Drop all staged changes, reverting to the last saved state.
class DiscardChanges extends MenuAdminEvent {
  const DiscardChanges();
}

// ── Menu groups (batch item-availability presets) ────────────────────────────

/// Create a new (inactive) menu group with the given name.
class CreateGroup extends MenuAdminEvent {
  final String name;

  const CreateGroup(this.name);

  @override
  List<Object?> get props => [name];
}

/// Rename an existing menu group.
class RenameGroup extends MenuAdminEvent {
  final int id;
  final String name;

  const RenameGroup(this.id, this.name);

  @override
  List<Object?> get props => [id, name];
}

/// Delete a menu group (its item config cascades away).
class DeleteGroup extends MenuAdminEvent {
  final int id;

  const DeleteGroup(this.id);

  @override
  List<Object?> get props => [id];
}

/// Make a group the single active one (drives the customer web menu).
class SelectActiveGroup extends MenuAdminEvent {
  final int id;

  const SelectActiveGroup(this.id);

  @override
  List<Object?> get props => [id];
}

/// Load a group's config into the editing surface so the checkboxes represent
/// that group. Passing null returns to editing the legacy per-item flags.
class EditGroup extends MenuAdminEvent {
  final int? id;

  const EditGroup(this.id);

  @override
  List<Object?> get props => [id];
}
