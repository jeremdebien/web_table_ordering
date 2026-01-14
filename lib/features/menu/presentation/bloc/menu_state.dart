part of 'menu_bloc.dart';

sealed class MenuState extends Equatable {
  const MenuState();

  @override
  List<Object?> get props => [];
}

class MenuInitial extends MenuState {
  const MenuInitial();
}

class MenuLoading extends MenuState {
  const MenuLoading();
}

class MenuLoaded extends MenuState {
  final List<DepartmentModel> departments;
  final List<CategoryModel> categories;
  final List<ItemModel> items;
  final int? selectedDepartmentId;
  final int? selectedCategoryId;

  const MenuLoaded({
    this.departments = const [],
    this.categories = const [],
    this.items = const [],
    this.selectedDepartmentId,
    this.selectedCategoryId,
  });

  MenuLoaded copyWith({
    List<DepartmentModel>? departments,
    List<CategoryModel>? categories,
    List<ItemModel>? items,
    int? selectedDepartmentId,
    int? selectedCategoryId,
  }) {
    return MenuLoaded(
      departments: departments ?? this.departments,
      categories: categories ?? this.categories,
      items: items ?? this.items,
      selectedDepartmentId: selectedDepartmentId ?? this.selectedDepartmentId,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
    );
  }

  @override
  List<Object?> get props => [
    departments,
    categories,
    items,
    selectedDepartmentId,
    selectedCategoryId,
  ];
}

class MenuError extends MenuState {
  final String message;

  const MenuError(this.message);

  @override
  List<Object?> get props => [message];
}
