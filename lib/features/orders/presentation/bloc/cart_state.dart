part of 'cart_bloc.dart';

enum CartStatus { initial, loading, success, failure, submitted }

class CartState {
  final List<SalesOrderItemModel> items;
  final CartStatus status;
  final String? errorMessage;
  final int paymentStatus;
  final int? salesOrderId;
  final String? deviceId;
  final String nickname;
  // True once LoadNickname has resolved (local storage / backend). Until then
  // an empty nickname means "not loaded yet", not "no nickname".
  final bool nicknameLoaded;
  // app_config 'allow_order_when_billed': guests may keep ordering while the
  // order is tempo billed (paymentStatus == 1).
  final bool allowOrderWhenBilled;
  // POS service-charge setup (service_charge row). Starts at the legacy flat
  // 10% until loaded.
  final ServiceChargeConfig serviceCharge;
  // Base barcodes of new lines the last submit was blocked on: sold out,
  // hidden, disabled or outside their POS schedule. The guest must remove them.
  final Set<String> unavailableBarcodes;

  const CartState({
    this.items = const [],
    this.status = CartStatus.initial,
    this.errorMessage,
    this.paymentStatus = 0,
    this.salesOrderId,
    this.deviceId,
    this.nickname = '',
    this.nicknameLoaded = false,
    this.allowOrderWhenBilled = false,
    this.serviceCharge = ServiceChargeConfig.legacy,
    this.unavailableBarcodes = const {},
  });

  /// Whether [line] was flagged unavailable by the last blocked submit.
  bool isUnavailable(SalesOrderItemModel line) =>
      line.originalQuantity == 0 && unavailableBarcodes.contains(line.baseVariantBarcode ?? line.itemBarcode);

  /// Service charge on [subtotal], computed the way the POS does.
  double serviceChargeFor(double subtotal) => serviceCharge.compute(subtotal);

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
    String? deviceId,
    String? nickname,
    bool? nicknameLoaded,
    bool? allowOrderWhenBilled,
    ServiceChargeConfig? serviceCharge,
    Set<String>? unavailableBarcodes,
  }) {
    return CartState(
      items: items ?? this.items,
      status: status ?? this.status,
      errorMessage: errorMessage,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      salesOrderId: salesOrderId ?? this.salesOrderId,
      deviceId: deviceId ?? this.deviceId,
      nickname: nickname ?? this.nickname,
      nicknameLoaded: nicknameLoaded ?? this.nicknameLoaded,
      allowOrderWhenBilled: allowOrderWhenBilled ?? this.allowOrderWhenBilled,
      serviceCharge: serviceCharge ?? this.serviceCharge,
      unavailableBarcodes: unavailableBarcodes ?? this.unavailableBarcodes,
    );
  }
}
