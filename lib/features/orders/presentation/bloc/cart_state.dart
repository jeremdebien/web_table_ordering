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

  double get totalAmount => items.fold(0.0, (total, current) => total + current.totalPrice);

  List<SalesOrderItemModel> get activeOrders =>
      items.where((i) => i.status == 'Accepted' && i.originalQuantity > 0).toList();
  int get activeOrderCount => activeOrders.length;
  double get activeOrderTotalAmount => activeOrders.fold(0.0, (total, current) => total + current.totalPrice);

  List<SalesOrderItemModel> get pendingOrders => items.where((i) => i.status == 'Pending').toList();
  int get pendingOrdersCount => pendingOrders.length;
  double get pendingOrderTotalAmount => pendingOrders.fold(0.0, (total, current) => total + current.totalPrice);

  List<SalesOrderItemModel> get newOrders => items.where((i) => i.originalQuantity == 0).toList();
  int get newOrdersCount => newOrders.length;
  double get newOrderTotalAmount => newOrders.fold(0.0, (total, current) => total + current.totalPrice);

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
