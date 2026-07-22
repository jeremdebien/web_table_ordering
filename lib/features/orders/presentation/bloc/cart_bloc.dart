import 'dart:async';
import 'package:rxdart/rxdart.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/presentation/bloc/menu_bloc.dart';

import '../../data/datasources/orders_data_source.dart';
import '../../../../core/utils/device_id_service.dart';

part 'cart_event.dart';
part 'cart_state.dart';

class CartBloc extends Bloc<CartEvent, CartState> {
  final OrdersDataSource _ordersDataSource;
  final MenuBloc _menuBloc;
  final DeviceIdService _deviceIdService;
  StreamSubscription? _menuSubscription;
  StreamSubscription? _realtimeSubscription;
  int? _subscribedSalesOrderId;

  CartBloc(this._ordersDataSource, this._menuBloc, this._deviceIdService) : super(const CartState()) {
    on<AddToCart>(_onAddToCart);
    on<RemoveFromCart>(_onRemoveFromCart);
    on<ClearCart>(_onClearCart);
    on<SubmitOrder>(_onSubmitOrder);
    on<LoadActiveOrder>(_onLoadActiveOrder);
    on<UpdateCartItemNames>(_onUpdateCartItemNames);
    on<EnableOrdering>(_onEnableOrdering);
    on<RequestBill>(_onRequestBill);
    on<LoadNickname>(_onLoadNickname);
    on<UpdateNickname>(_onUpdateNickname);
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
    add(LoadActiveOrder(event.tableId, isBackground: true));
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
    final deviceId = _deviceIdService.getDeviceId();
    // A background refresh (realtime: POS edit, or the kitchen scanning a
    // ticket) must not flash the loading state over a guest who is mid-order.
    if (event.isBackground) {
      emit(state.copyWith(deviceId: deviceId));
    } else {
      emit(state.copyWith(status: CartStatus.loading, deviceId: deviceId));
    }
    // Items the guest has added but not submitted yet live in the same list as
    // the server's lines, so a refresh would otherwise wipe them. Hold them
    // aside and re-append below.
    final unsubmitted = state.newOrders;
    try {
      final order = await _ordersDataSource.getActiveOrder(tableId: event.tableId);
      if (order != null) {
        var items = [...order.items, ...unsubmitted];
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

        _subscribeToRealtimeUpdates(order.id, sOrderId, event.tableId);

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
        emit(state.copyWith(
          status: CartStatus.success,
          items: unsubmitted,
          paymentStatus: 0,
          salesOrderId: null,
        ));
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

      // Drop the just-submitted lines: they belong to the backend now and come
      // back as accepted items on the reload below. Leaving them in state would
      // double them up, since a reload preserves anything still unsubmitted.
      emit(state.copyWith(
        status: CartStatus.submitted,
        items: state.items.where((i) => i.originalQuantity > 0).toList(),
      ));

      // Reload the active order to reflect merged state from backend
      add(LoadActiveOrder(event.tableId));
    } catch (e) {
      emit(state.copyWith(status: CartStatus.failure, errorMessage: e.toString()));
    }
  }

  void _onAddToCart(AddToCart event, Emitter<CartState> emit) {
    // Find existing "New" item (originalQuantity == 0). Only merge when the
    // orderer AND the special-instruction answers also match, so the same item
    // with different instructions (or a different guest) stays a separate line.
    final existingNewIndex = state.items.indexWhere(
      (i) =>
          i.itemBarcode == event.item.itemBarcode &&
          i.originalQuantity == 0 &&
          i.nickname == state.nickname &&
          (i.specialInstructions ?? '') == (event.item.specialInstructions ?? ''),
    );

    if (existingNewIndex >= 0) {
      final updatedItems = List<SalesOrderItemModel>.from(state.items);
      final existingItem = updatedItems[existingNewIndex];

      // Calculate new quantity and amount
      final newQuantity = existingItem.quantity + event.item.quantity;
      // Amount is now unit price, so we don't change it.
      // final newAmount = existingItem.amount + event.item.amount;

      updatedItems[existingNewIndex] = existingItem.copyWith(
        quantity: newQuantity,
        // amount: newAmount, // Keep original unit price
      );
      emit(state.copyWith(items: updatedItems));
    } else {
      // Add as a new row, even if an "Old" item exists
      // Tag it with current nickname
      final itemWithNickname = event.item.copyWith(nickname: state.nickname);
      emit(state.copyWith(items: [...state.items, itemWithNickname]));
    }
  }

  Future<void> _onLoadNickname(LoadNickname event, Emitter<CartState> emit) async {
    final deviceId = _deviceIdService.getDeviceId();
    String? nickname = _deviceIdService.getNickname();

    if (nickname == null) {
      // Try fetching from database as backup
      nickname = await _ordersDataSource.getNicknameByDeviceId(deviceId);
      if (nickname != null) {
        await _deviceIdService.saveNickname(nickname);
      }
    }

    emit(state.copyWith(deviceId: deviceId, nickname: nickname ?? ''));
  }

  Future<void> _onUpdateNickname(UpdateNickname event, Emitter<CartState> emit) async {
    final deviceId = state.deviceId ?? _deviceIdService.getDeviceId();
    await _deviceIdService.saveNickname(event.nickname);
    await _ordersDataSource.upsertCustomer(deviceId, event.nickname);

    // Update any NEW (unsubmitted) items in the cart with the new nickname
    final updatedItems = state.items.map((i) {
      if (i.originalQuantity == 0) {
        return i.copyWith(nickname: event.nickname);
      }
      return i;
    }).toList();

    emit(state.copyWith(nickname: event.nickname, items: updatedItems));
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
