part of 'cart_bloc.dart';

class CartState {
  final List<SalesOrderItemModel> items;

  const CartState({
    this.items = const [],
  });

  double get totalAmount => items.fold(0.0, (total, current) => total + current.amount);

  CartState copyWith({
    List<SalesOrderItemModel>? items,
  }) {
    return CartState(
      items: items ?? this.items,
    );
  }
}
