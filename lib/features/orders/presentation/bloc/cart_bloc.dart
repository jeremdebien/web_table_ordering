import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';

part 'cart_event.dart';
part 'cart_state.dart';

class CartBloc extends Bloc<CartEvent, CartState> {
  CartBloc() : super(const CartState()) {
    on<AddToCart>(_onAddToCart);
    on<RemoveFromCart>(_onRemoveFromCart);
    on<ClearCart>(_onClearCart);
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
