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

class ClearCart extends CartEvent {
  ClearCart();
}

class SubmitOrder extends CartEvent {
  final int tableId;
  final int guestCount;

  SubmitOrder({required this.tableId, required this.guestCount});
}

class LoadActiveOrder extends CartEvent {
  final int tableId;

  /// A refresh the guest did not ask for — a realtime update from the POS or
  /// the kitchen's ticket scanner. Keeps the cart quiet (no loading state) so
  /// the screen doesn't flicker underneath someone who is mid-order.
  final bool isBackground;

  LoadActiveOrder(this.tableId, {this.isBackground = false});
}

class UpdateCartItemNames extends CartEvent {
  final List<ItemModel> menuItems;
  UpdateCartItemNames(this.menuItems);
}

class EnableOrdering extends CartEvent {
  final int tableId;
  EnableOrdering(this.tableId);
}

class RequestBill extends CartEvent {
  final int tableId;
  RequestBill(this.tableId);
}

class ExternalOrderUpdateReceived extends CartEvent {
  final int tableId;
  ExternalOrderUpdateReceived(this.tableId);
}

class LoadNickname extends CartEvent {}

class UpdateNickname extends CartEvent {
  final String nickname;
  UpdateNickname(this.nickname);
}
