part of 'clear_orders_bloc.dart';

abstract class ClearOrdersState extends Equatable {
  const ClearOrdersState();

  @override
  List<Object?> get props => [];
}

class ClearOrdersInitial extends ClearOrdersState {
  const ClearOrdersInitial();
}

class ClearOrdersLoading extends ClearOrdersState {
  const ClearOrdersLoading();
}

class ClearOrdersError extends ClearOrdersState {
  final String message;
  const ClearOrdersError(this.message);

  @override
  List<Object?> get props => [message];
}

/// Sentinel so `copyWith` can distinguish "leave as-is" from "reset to null"
/// for the transient [clearError].
const _unset = Object();

class ClearOrdersLoaded extends ClearOrdersState {
  final List<GroundModel> grounds;
  final List<TableModel> tables;

  /// `tableId → open order` for every table with `payment_status IN (0,1)`.
  final Map<int, SalesOrderModel> openOrders;

  final int? selectedGroundId;
  final String query;
  final bool openOnly;
  final bool isClearing;

  /// Transient error from the last clear attempt (shown once via snackbar).
  final String? clearError;

  const ClearOrdersLoaded({
    required this.grounds,
    required this.tables,
    required this.openOrders,
    this.selectedGroundId,
    this.query = '',
    this.openOnly = false,
    this.isClearing = false,
    this.clearError,
  });

  /// The currently selected ground, or null.
  GroundModel? get selectedGround {
    for (final g in grounds) {
      if (g.id == selectedGroundId) return g;
    }
    return null;
  }

  bool isOpen(int tableId) => openOrders.containsKey(tableId);

  /// Tables that pass the current search + open-only filter (across all grounds).
  bool tableMatchesFilter(TableModel t) {
    if (openOnly && !isOpen(t.id)) return false;
    if (query.isNotEmpty && !t.description.toLowerCase().contains(query.toLowerCase())) {
      return false;
    }
    return true;
  }

  ClearOrdersLoaded copyWith({
    List<GroundModel>? grounds,
    List<TableModel>? tables,
    Map<int, SalesOrderModel>? openOrders,
    int? selectedGroundId,
    String? query,
    bool? openOnly,
    bool? isClearing,
    Object? clearError = _unset,
  }) {
    return ClearOrdersLoaded(
      grounds: grounds ?? this.grounds,
      tables: tables ?? this.tables,
      openOrders: openOrders ?? this.openOrders,
      selectedGroundId: selectedGroundId ?? this.selectedGroundId,
      query: query ?? this.query,
      openOnly: openOnly ?? this.openOnly,
      isClearing: isClearing ?? this.isClearing,
      clearError: identical(clearError, _unset) ? this.clearError : clearError as String?,
    );
  }

  @override
  List<Object?> get props => [
        grounds,
        tables,
        openOrders,
        selectedGroundId,
        query,
        openOnly,
        isClearing,
        clearError,
      ];
}
