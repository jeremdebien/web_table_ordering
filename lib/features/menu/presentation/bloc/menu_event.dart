part of 'menu_bloc.dart';

abstract class MenuEvent extends Equatable {
  const MenuEvent();

  @override
  List<Object?> get props => [];
}

class LoadMenu extends MenuEvent {}

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
