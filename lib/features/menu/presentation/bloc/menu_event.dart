part of 'menu_bloc.dart';

abstract class MenuEvent extends Equatable {
  const MenuEvent();

  @override
  List<Object?> get props => [];
}

class LoadMenu extends MenuEvent {}

/// Minute tick: re-evaluate POS schedule rules so time windows open and close
/// without a reload.
class AvailabilityTick extends MenuEvent {
  const AvailabilityTick();
}

/// An `item` row changed on the POS (sold out, hidden, disabled...): re-fetch
/// the menu in the background, keeping the current selection.
class ItemsChanged extends MenuEvent {
  const ItemsChanged();
}

/// Whether a staff member is logged in on this device. Staff-only items are
/// included in the menu while true; reloads the menu when it changes.
class SetStaffMode extends MenuEvent {
  final bool isStaff;

  const SetStaffMode(this.isStaff);

  @override
  List<Object?> get props => [isStaff];
}

class SelectDepartment extends MenuEvent {
  final int departmentId;

  const SelectDepartment(this.departmentId);

  @override
  List<Object?> get props => [departmentId];
}

class SelectCategory extends MenuEvent {
  final int categoryId;

  const SelectCategory(this.categoryId);

  @override
  List<Object?> get props => [categoryId];
}
