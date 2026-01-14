import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';

import '../../data/datasources/orders_supabase_datasource.dart';

part 'cart_event.dart';
part 'cart_state.dart';

class CartBloc extends Bloc<CartEvent, CartState> {
  final OrdersSupabaseDataSource _ordersDataSource;

  CartBloc(this._ordersDataSource) : super(const CartState()) {
    on<AddToCart>(_onAddToCart);
    on<RemoveFromCart>(_onRemoveFromCart);
    on<ClearCart>(_onClearCart);
    on<SubmitOrder>(_onSubmitOrder);
  }

  Future<void> _onSubmitOrder(SubmitOrder event, Emitter<CartState> emit) async {
    emit(state.copyWith(status: CartStatus.loading));
    try {
      await _ordersDataSource.submitSalesOrder(
        tableId: event.tableId,
        guestCount: event.guestCount,
        items: state.items,
      );
      emit(state.copyWith(status: CartStatus.success, items: []));
    } catch (e) {
      emit(state.copyWith(status: CartStatus.failure, errorMessage: e.toString()));
    }
  }

  void _onAddToCart(AddToCart event, Emitter<CartState> emit) {
    final existingIndex = state.items.indexWhere((i) => i.itemBarcode == event.item.itemBarcode);
    if (existingIndex >= 0) {
      final updatedItems = List<SalesOrderItemModel>.from(state.items);
      final existingItem = updatedItems[existingIndex];

      // Calculate new quantity and amount
      final newQuantity = existingItem.quantity + event.item.quantity;
      final newAmount = existingItem.amount + event.item.amount;

      updatedItems[existingIndex] = existingItem.copyWith(
        quantity: newQuantity,
        amount: newAmount,
      );
      emit(state.copyWith(items: updatedItems));
    } else {
      emit(state.copyWith(items: [...state.items, event.item]));
    }
  }

  void _onRemoveFromCart(RemoveFromCart event, Emitter<CartState> emit) {
    final updatedItems = state.items.where((i) => i.itemBarcode != event.item.itemBarcode).toList();
    emit(state.copyWith(items: updatedItems));
  }

  void _onClearCart(ClearCart event, Emitter<CartState> emit) {
    emit(state.copyWith(items: []));
  }
}
