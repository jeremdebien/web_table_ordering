import '../models/sales_order_model.dart';
import '../models/sales_order_item_model.dart';

/// Thrown when a guest tries to order at a table the POS has split into multiple
/// bills. The web app has no UI to pick which bill new items join, so it stops
/// here rather than guessing (or crashing on the multi-row header read). The
/// message is guest-facing verbatim.
class SplitTableException implements Exception {
  static const friendlyMessage =
      'This table is being split into separate bills. Please ask a staff member to add your order.';

  final String message;
  const SplitTableException([this.message = friendlyMessage]);

  @override
  String toString() => message;
}

/// Read/write contract for orders, implemented per app mode
/// (online: Edge Functions + pending stage, local: direct writes).
abstract class OrdersDataSource {
  Future<void> submitSalesOrder({
    required int tableId,
    required int guestCount,
    required List<SalesOrderItemModel> items,
  });

  Future<void> updatePaymentStatus({
    required int tableId,
    required int status,
    int? salesOrderId,
  });

  /// Marks every still-open KDS order (and its non-cancelled items) for this
  /// sales order as completed, so clearing a table also clears its kitchen
  /// cards. Server-side via the `kds_complete_sales_order` RPC (migration 0053);
  /// cancelled/already-completed rows are left untouched.
  Future<void> completeKdsForSalesOrder(int salesOrderId);

  Stream<List<Map<String, dynamic>>> subscribeToOrderUpdates({int? tableId});

  Stream<void> subscribeToActiveOrderChanges(
    int salesOrderSupabaseId,
    int salesOrderId,
  );

  /// Active order for a table. When [deviceId] is provided, the returned line
  /// items are filtered to that ordering device (the header stays table-wide).
  Future<SalesOrderModel?> getActiveOrder({required int tableId, String? deviceId});

  Future<List<SalesOrderModel>> getOrders({int? tableId});

  /// All currently open orders (payment_status IN (0,1)), headers only (no line
  /// items). Used by the staff clear-orders floor plan to color tables by state
  /// without the per-order item fetch that `getOrders` does. Local-mode only.
  Future<List<SalesOrderModel>> getOpenOrders();

  Future<String?> getNicknameByDeviceId(String deviceId);

  Future<void> upsertCustomer(String deviceId, String nickname);
}
