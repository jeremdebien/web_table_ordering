part of 'cart_bloc.dart';

enum CartStatus { initial, loading, success, failure }

class CartState {
  final List<SalesOrderItemModel> items;
  final CartStatus status;
  final String? errorMessage;

  const CartState({
    this.items = const [],
    this.status = CartStatus.initial,
    this.errorMessage,
  });

  double get totalAmount => items.fold(0.0, (total, current) => total + current.amount);

  CartState copyWith({
    List<SalesOrderItemModel>? items,
    CartStatus? status,
    String? errorMessage,
  }) {
    return CartState(
      items: items ?? this.items,
      status: status ?? this.status,
      errorMessage: errorMessage,
    );
  }
}
