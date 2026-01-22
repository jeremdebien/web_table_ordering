import 'dart:async';
import 'package:rxdart/rxdart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/presentation/bloc/menu_bloc.dart';

import '../../data/datasources/orders_supabase_datasource.dart';

part 'cart_event.dart';
part 'cart_state.dart';

class CartBloc extends Bloc<CartEvent, CartState> {
  final OrdersSupabaseDataSource _ordersDataSource;
  final MenuBloc _menuBloc;
  StreamSubscription? _menuSubscription;
  StreamSubscription? _realtimeSubscription;
  int? _subscribedSalesOrderId;

  CartBloc(this._ordersDataSource, this._menuBloc) : super(const CartState()) {
    on<AddToCart>(_onAddToCart);
    on<RemoveFromCart>(_onRemoveFromCart);
    on<ClearCart>(_onClearCart);
    on<SubmitOrder>(_onSubmitOrder);
    on<LoadActiveOrder>(_onLoadActiveOrder);
    on<UpdateCartItemNames>(_onUpdateCartItemNames);
    on<EnableOrdering>(_onEnableOrdering);
    on<RequestBill>(_onRequestBill);
    on<ExternalOrderUpdateReceived>(
      _onExternalOrderUpdateReceived,
      transformer: (events, mapper) => events.debounceTime(const Duration(milliseconds: 500)).asyncExpand(mapper),
    );

    _menuSubscription = _menuBloc.stream.listen((menuState) {
      if (menuState is MenuLoaded) {
        add(UpdateCartItemNames(menuState.items));
      }
    });
  }

  @override
  Future<void> close() {
    _menuSubscription?.cancel();
    _realtimeSubscription?.cancel();
    return super.close();
  }

  void _onUpdateCartItemNames(UpdateCartItemNames event, Emitter<CartState> emit) {
    if (state.items.isEmpty) return;

    final updatedItems = state.items.map((i) {
      if (i.itemName.isEmpty || i.itemName == 'Unknown Item') {
        final found = event.menuItems.where((m) => m.barcode == i.itemBarcode).firstOrNull;
        if (found != null) {
          return i.copyWith(itemName: found.name);
        }
      }
      return i;
    }).toList();

    emit(state.copyWith(items: updatedItems));
  }

  Future<void> _onExternalOrderUpdateReceived(ExternalOrderUpdateReceived event, Emitter<CartState> emit) async {
    add(LoadActiveOrder(event.tableId));
  }

  void _subscribeToRealtimeUpdates(int salesOrderSupabaseId, int salesOrderId, int tableId) {
    if (_subscribedSalesOrderId == salesOrderId) return;

    _realtimeSubscription?.cancel();
    _subscribedSalesOrderId = salesOrderId;

    _realtimeSubscription = _ordersDataSource.subscribeToActiveOrderChanges(salesOrderSupabaseId, salesOrderId).listen((
      _,
    ) {
      add(ExternalOrderUpdateReceived(tableId));
    });
  }

  Future<void> _onLoadActiveOrder(LoadActiveOrder event, Emitter<CartState> emit) async {
    // Only show loading if we are NOT already conducting a background refresh?
    // For now, let's keep it standard to ensure UI consistency.
    emit(state.copyWith(status: CartStatus.loading));
    try {
      final order = await _ordersDataSource.getActiveOrder(tableId: event.tableId);
      if (order != null) {
        var items = order.items;
        final sOrderId = order.salesOrderId ?? order.id;

        // Map names immediately if menu is loaded
        if (_menuBloc.state is MenuLoaded) {
          final menuItems = (_menuBloc.state as MenuLoaded).items;
          items = items.map((i) {
            if (i.itemName.isEmpty) {
              final found = menuItems.where((m) => m.barcode == i.itemBarcode).firstOrNull;
              if (found != null) {
                return i.copyWith(itemName: found.name);
              }
            }
            return i;
          }).toList();
        }

        if (sOrderId != null) {
          _subscribeToRealtimeUpdates(order.id, sOrderId, event.tableId);
        }

        emit(
          state.copyWith(
            status: CartStatus.success,
            items: items,
            paymentStatus: order.paymentStatus,
            salesOrderId: sOrderId,
          ),
        );
      } else {
        // If no order, cancel subscription
        _realtimeSubscription?.cancel();
        _subscribedSalesOrderId = null;
        emit(state.copyWith(status: CartStatus.success, items: [], paymentStatus: 0, salesOrderId: null));
      }
    } catch (e) {
      emit(state.copyWith(status: CartStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _onSubmitOrder(SubmitOrder event, Emitter<CartState> emit) async {
    emit(state.copyWith(status: CartStatus.loading));
    try {
      // Filter only NEW items (originalQuantity == 0)
      final itemsToSubmit = state.newOrders;

      if (itemsToSubmit.isNotEmpty) {
        await _ordersDataSource.submitSalesOrder(
          tableId: event.tableId,
          guestCount: event.guestCount,
          items: itemsToSubmit,
        );
      }

      emit(state.copyWith(status: CartStatus.submitted));

      // Reload the active order to reflect merged state from backend
      add(LoadActiveOrder(event.tableId));
    } catch (e) {
      emit(state.copyWith(status: CartStatus.failure, errorMessage: e.toString()));
    }
  }

  void _onAddToCart(AddToCart event, Emitter<CartState> emit) {
    // Find existing "New" item (originalQuantity == 0)
    // We intentionally ignore items with originalQuantity > 0 (Preloaded items)
    final existingNewIndex = state.items.indexWhere(
      (i) => i.itemBarcode == event.item.itemBarcode && i.originalQuantity == 0,
    );

    if (existingNewIndex >= 0) {
      final updatedItems = List<SalesOrderItemModel>.from(state.items);
      final existingItem = updatedItems[existingNewIndex];

      // Calculate new quantity and amount
      final newQuantity = existingItem.quantity + event.item.quantity;
      final newAmount = existingItem.amount + event.item.amount;

      updatedItems[existingNewIndex] = existingItem.copyWith(
        quantity: newQuantity,
        amount: newAmount,
      );
      emit(state.copyWith(items: updatedItems));
    } else {
      // Add as a new row, even if an "Old" item exists
      emit(state.copyWith(items: [...state.items, event.item]));
    }
  }

  void _onRemoveFromCart(RemoveFromCart event, Emitter<CartState> emit) {
    // Remove specific item instance (handling duplicates carefully if necessary,
    // but here we likely rely on object identity or we might need a unique ID.
    // For now assuming object instance or index removal is desired, but
    // typical List.where removes ALL matches.
    // Given we might have two "Burgers", we should probably remove by specific ID or
    // if using instance reference, we need to be careful.
    // Let's assume we remove by identity for now or index.
    // Actually, checking equality: existing logic uses barcode.
    // WE MUST CHANGE THIS to avoid removing both Old and New lines.

    // Better strategy: Remove the specific item passed in the event.
    // If the event.item is the exact object from the list:
    final updatedItems = List<SalesOrderItemModel>.from(state.items);
    updatedItems.remove(event.item);
    emit(state.copyWith(items: updatedItems));
  }

  void _onClearCart(ClearCart event, Emitter<CartState> emit) {
    emit(state.copyWith(items: []));
  }

  Future<void> _onEnableOrdering(EnableOrdering event, Emitter<CartState> emit) async {
    emit(state.copyWith(status: CartStatus.loading));
    try {
      await _ordersDataSource.updatePaymentStatus(tableId: event.tableId, status: 0);
      add(LoadActiveOrder(event.tableId));
    } catch (e) {
      emit(state.copyWith(status: CartStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _onRequestBill(RequestBill event, Emitter<CartState> emit) async {
    emit(state.copyWith(status: CartStatus.loading));
    try {
      await _ordersDataSource.updatePaymentStatus(tableId: event.tableId, status: 1);
      add(LoadActiveOrder(event.tableId));
    } catch (e) {
      emit(state.copyWith(status: CartStatus.failure, errorMessage: e.toString()));
    }
  }
}
