part of 'clear_orders_bloc.dart';

abstract class ClearOrdersEvent extends Equatable {
  const ClearOrdersEvent();

  @override
  List<Object?> get props => [];
}

/// Load grounds, tables and the current open orders.
class LoadTables extends ClearOrdersEvent {
  const LoadTables();
}

/// Switch the visible ground (floor/section).
class SelectGround extends ClearOrdersEvent {
  final int groundId;
  const SelectGround(this.groundId);

  @override
  List<Object?> get props => [groundId];
}

/// Update the table-name search filter.
class SearchChanged extends ClearOrdersEvent {
  final String query;
  const SearchChanged(this.query);

  @override
  List<Object?> get props => [query];
}

/// Toggle showing only tables with an open order.
class ToggleOpenOnly extends ClearOrdersEvent {
  final bool openOnly;
  const ToggleOpenOnly(this.openOnly);

  @override
  List<Object?> get props => [openOnly];
}

/// Clear (settle) a table's open order → `payment_status = 2`.
class ClearTable extends ClearOrdersEvent {
  final int tableId;
  final int? salesOrderId;
  const ClearTable({required this.tableId, this.salesOrderId});

  @override
  List<Object?> get props => [tableId, salesOrderId];
}

/// Cancel (void) a table's open order, mirroring the POS "Cancel Table":
/// the order and its items are deleted and the kitchen gets cancel slips.
class CancelTable extends ClearOrdersEvent {
  final int tableId;
  final int salesOrderId;
  const CancelTable({required this.tableId, required this.salesOrderId});

  @override
  List<Object?> get props => [tableId, salesOrderId];
}
