import '../models/sales_order_model.dart';
import '../models/sales_order_item_model.dart';

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

  Stream<List<Map<String, dynamic>>> subscribeToOrderUpdates({int? tableId});

  Stream<void> subscribeToActiveOrderChanges(
    int salesOrderSupabaseId,
    int salesOrderId,
  );

  /// Active order for a table. When [deviceId] is provided, the returned line
  /// items are filtered to that ordering device (the header stays table-wide).
  Future<SalesOrderModel?> getActiveOrder({required int tableId, String? deviceId});

  Future<List<SalesOrderModel>> getOrders({int? tableId});

  Future<String?> getNicknameByDeviceId(String deviceId);

  Future<void> upsertCustomer(String deviceId, String nickname);
}
