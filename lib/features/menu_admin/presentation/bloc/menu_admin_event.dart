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
