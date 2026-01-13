import 'package:equatable/equatable.dart';

abstract class MenuEvent extends Equatable {
  const MenuEvent();

  @override
  List<Object?> get props => [];
}

class GetDepartments extends MenuEvent {}

class GetCategories extends MenuEvent {
  final int departmentId;

  const GetCategories(this.departmentId);

  @override
  List<Object?> get props => [departmentId];
}

class GetItems extends MenuEvent {
  final int categoryId;

  const GetItems(this.categoryId);

  @override
  List<Object?> get props => [categoryId];
}
