part of 'menu_bloc.dart';

abstract class MenuEvent extends Equatable {
  const MenuEvent();

  @override
  List<Object?> get props => [];
}

class LoadMenu extends MenuEvent {}

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
