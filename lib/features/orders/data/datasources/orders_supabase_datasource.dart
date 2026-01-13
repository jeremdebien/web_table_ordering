import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/sales_order_model.dart';

class OrdersSupabaseDataSource {
  final SupabaseClient _client;

  OrdersSupabaseDataSource(this._client);

  /// Create a new order
  /// Uses a hypothetical Edge Function 'submit-order' to handle complex
  /// logic like creating the order and its items transactionally.
  /// Alternatively, this could be a direct RPC call or detailed client-side inserts.
  Future<void> createOrder(SalesOrderModel order) async {
    try {
      await _client.functions.invoke('submit-order', body: order.toJson());
    } catch (e) {
      throw Exception('Failed to create order: $e');
    }
  }

  /// Subscribe to order updates for a specific table or all orders
  /// Useful for the Order Summary screen.
  Stream<List<Map<String, dynamic>>> subscribeToOrderUpdates({String? tableUuid}) {
    final builder = _client.from('sales_orders').stream(primaryKey: ['id']);

    if (tableUuid != null) {
      return builder.eq('table_uuid', tableUuid).order('created_at', ascending: false);
    }

    return builder.order('created_at', ascending: false);
  }

  /// Fetch orders (e.g. for history)
  Future<List<SalesOrderModel>> getOrders({String? tableUuid}) async {
    var query = _client.from('sales_orders').select('*, sales_order_items(*)'); // Join with items

    if (tableUuid != null) {
      query = query.eq('table_uuid', tableUuid);
    }

    final response = await query.order('created_at', ascending: false);
    return (response as List).map((e) => SalesOrderModel.fromJson(e)).toList();
  }
}
