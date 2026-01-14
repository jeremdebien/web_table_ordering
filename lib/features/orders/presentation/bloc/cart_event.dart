part of 'cart_bloc.dart';

abstract class CartEvent {}

class AddToCart extends CartEvent {
  final SalesOrderItemModel item;
  AddToCart(this.item);
}

class RemoveFromCart extends CartEvent {
  final SalesOrderItemModel item;
  RemoveFromCart(this.item);
}

class ClearCart extends CartEvent {}

class SubmitOrder extends CartEvent {
  final int tableId;
  final int guestCount;

  SubmitOrder({required this.tableId, required this.guestCount});
}

class LoadActiveOrder extends CartEvent {
  final int tableId;

  LoadActiveOrder(this.tableId);
}

class UpdateCartItemNames extends CartEvent {
  final List<ItemModel> menuItems;
  UpdateCartItemNames(this.menuItems);
}
