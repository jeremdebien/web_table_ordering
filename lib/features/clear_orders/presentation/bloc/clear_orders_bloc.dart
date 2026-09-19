import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../orders/data/datasources/orders_data_source.dart';
import '../../../orders/data/models/sales_order_model.dart';
import '../../../table/data/datasources/table_data_source.dart';
import '../../../table/data/models/ground_model.dart';
import '../../../table/data/models/layout_item_model.dart';
import '../../../table/data/models/table_model.dart';

part 'clear_orders_event.dart';
part 'clear_orders_state.dart';

/// Drives the staff "Clear Orders" floor plan (`/staff/tables`): lists grounds
/// and tables, colors each table by its open order, and clears (settles) a
/// table's order by setting `payment_status = 2`.
///
/// Local-mode only — the underlying data-source methods (`getGrounds`,
/// `getTables`, `getOpenOrders`) throw in online mode.
class ClearOrdersBloc extends Bloc<ClearOrdersEvent, ClearOrdersState> {
  final TableDataSource _tableDataSource;
  final OrdersDataSource _ordersDataSource;

  ClearOrdersBloc(this._tableDataSource, this._ordersDataSource)
      : super(const ClearOrdersInitial()) {
    on<LoadTables>(_onLoad);
    on<SelectGround>(_onSelectGround);
    on<SearchChanged>(_onSearch);
    on<ToggleOpenOnly>(_onToggleOpenOnly);
    on<ClearTable>(_onClearTable);
  }

  Future<void> _onLoad(LoadTables event, Emitter<ClearOrdersState> emit) async {
    emit(const ClearOrdersLoading());
    try {
      final results = await Future.wait([
        _tableDataSource.getGrounds(),
        _tableDataSource.getTables(),
        _ordersDataSource.getOpenOrders(),
        // Decoration only: a failure (e.g. table missing) must not block the
        // floor plan, so fall back to no structures.
        _tableDataSource.getLayoutItems().catchError((_) => <LayoutItemModel>[]),
      ]);
      final grounds = results[0] as List<GroundModel>;
      final tables = results[1] as List<TableModel>;
      final openOrders = results[2] as List<SalesOrderModel>;
      final layoutItems = results[3] as List<LayoutItemModel>;

      emit(
        ClearOrdersLoaded(
          grounds: grounds,
          tables: tables,
          layoutItems: layoutItems,
          openOrders: {for (final o in openOrders) o.tableId: o},
          selectedGroundId: grounds.isNotEmpty ? grounds.first.id : null,
        ),
      );
    } catch (e) {
      emit(ClearOrdersError(e.toString()));
    }
  }

  void _onSelectGround(SelectGround event, Emitter<ClearOrdersState> emit) {
    final s = state;
    if (s is! ClearOrdersLoaded) return;
    emit(s.copyWith(selectedGroundId: event.groundId));
  }

  void _onSearch(SearchChanged event, Emitter<ClearOrdersState> emit) {
    final s = state;
    if (s is! ClearOrdersLoaded) return;
    emit(s.copyWith(query: event.query));
  }

  void _onToggleOpenOnly(ToggleOpenOnly event, Emitter<ClearOrdersState> emit) {
    final s = state;
    if (s is! ClearOrdersLoaded) return;
    emit(s.copyWith(openOnly: event.openOnly));
  }

  Future<void> _onClearTable(ClearTable event, Emitter<ClearOrdersState> emit) async {
    final s = state;
    if (s is! ClearOrdersLoaded || s.isClearing) return;
    emit(s.copyWith(isClearing: true, clearError: null));
    try {
      await _ordersDataSource.updatePaymentStatus(
        tableId: event.tableId,
        status: 2, // paid / closed
        salesOrderId: event.salesOrderId,
      );
      // Also complete this order's still-open KDS cards so the kitchen board
      // clears with the table. Best-effort: a KDS hiccup must not leave the
      // table stuck open (payment_status is already settled above).
      if (event.salesOrderId != null) {
        try {
          await _ordersDataSource.completeKdsForSalesOrder(event.salesOrderId!);
        } catch (_) {}
      }
      // Refresh open orders so the cleared table flips to available.
      final openOrders = await _ordersDataSource.getOpenOrders();
      emit(
        s.copyWith(
          isClearing: false,
          openOrders: {for (final o in openOrders) o.tableId: o},
        ),
      );
    } catch (e) {
      emit(s.copyWith(isClearing: false, clearError: e.toString()));
    }
  }
}
