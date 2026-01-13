import 'package:equatable/equatable.dart';
import '../../data/models/department_model.dart';
import '../../data/models/category_model.dart';
import '../../data/models/item_model.dart';

enum MenuStatus { initial, loading, success, failure }

class MenuState extends Equatable {
  final MenuStatus status;
  final List<DepartmentModel> departments;
  final List<CategoryModel> categories;
  final List<ItemModel> items;
  final String? errorMessage;

  // Track specific selection if needed, or just keep it simple
  final int? selectedDepartmentId;
  final int? selectedCategoryId;

  const MenuState({
    this.status = MenuStatus.initial,
    this.departments = const [],
    this.categories = const [],
    this.items = const [],
    this.errorMessage,
    this.selectedDepartmentId,
    this.selectedCategoryId,
  });

  MenuState copyWith({
    MenuStatus? status,
    List<DepartmentModel>? departments,
    List<CategoryModel>? categories,
    List<ItemModel>? items,
    String? errorMessage,
    int? selectedDepartmentId,
    int? selectedCategoryId,
  }) {
    return MenuState(
      status: status ?? this.status,
      departments: departments ?? this.departments,
      categories: categories ?? this.categories,
      items: items ?? this.items,
      errorMessage: errorMessage ?? this.errorMessage,
      selectedDepartmentId: selectedDepartmentId ?? this.selectedDepartmentId,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
    );
  }

  @override
  List<Object?> get props => [
    status,
    departments,
    categories,
    items,
    errorMessage,
    selectedDepartmentId,
    selectedCategoryId,
  ];
}
