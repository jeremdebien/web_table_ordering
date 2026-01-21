part of 'cart_bloc.dart';

enum CartStatus { initial, loading, success, failure, submitted }

class CartState {
  final List<SalesOrderItemModel> items;
  final CartStatus status;
  final String? errorMessage;
  final int paymentStatus;
  final int? salesOrderId;

  const CartState({
    this.items = const [],
    this.status = CartStatus.initial,
    this.errorMessage,
    this.paymentStatus = 0,
    this.salesOrderId,
  });

  double get totalAmount => items.fold(0.0, (total, current) => total + current.amount);

  CartState copyWith({
    List<SalesOrderItemModel>? items,
    CartStatus? status,
    String? errorMessage,
    int? paymentStatus,
    int? salesOrderId,
  }) {
    return CartState(
      items: items ?? this.items,
      status: status ?? this.status,
      errorMessage: errorMessage,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      salesOrderId: salesOrderId ?? this.salesOrderId,
    );
  }
}
