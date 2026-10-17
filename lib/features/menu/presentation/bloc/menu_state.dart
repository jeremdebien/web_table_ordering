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
  /// POS schedule rules + holidays, evaluated against [now].
  final AvailabilitySnapshot availability;
  /// Clock the schedule is evaluated at; advanced by the minute tick.
  final DateTime? now;

  const MenuLoaded({
    this.departments = const [],
    this.categories = const [],
    this.items = const [],
    this.selectedDepartmentId,
    this.selectedCategoryId,
    this.availability = AvailabilitySnapshot.empty,
    this.now,
  });

  /// Why [item] can't be ordered right now (sold out / outside its POS
  /// schedule), or null if it can.
  String? unavailableReason(ItemModel item) =>
      availability.unavailableReason(item, now ?? DateTime.now());

  MenuLoaded copyWith({
    List<DepartmentModel>? departments,
    List<CategoryModel>? categories,
    List<ItemModel>? items,
    int? selectedDepartmentId,
    int? selectedCategoryId,
    AvailabilitySnapshot? availability,
    DateTime? now,
  }) {
    return MenuLoaded(
      departments: departments ?? this.departments,
      categories: categories ?? this.categories,
      items: items ?? this.items,
      selectedDepartmentId: selectedDepartmentId ?? this.selectedDepartmentId,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
      availability: availability ?? this.availability,
      now: now ?? this.now,
    );
  }

  @override
  List<Object?> get props => [
    departments,
    categories,
    items,
    selectedDepartmentId,
    selectedCategoryId,
    availability,
    now,
  ];
}

class MenuError extends MenuState {
  final String message;

  const MenuError(this.message);

  @override
  List<Object?> get props => [message];
}
