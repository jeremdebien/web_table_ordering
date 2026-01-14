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
