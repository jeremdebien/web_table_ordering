import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/sales_order_model.dart';
import '../models/sales_order_item_model.dart';

class OrdersSupabaseDataSource {
  final SupabaseClient _client;

  OrdersSupabaseDataSource(this._client);

  /// Create a new order
  /// Uses a hypothetical Edge Function 'submit-order' to handle complex
  /// logic like creating the order and its items transactionally.
  /// Alternatively, this could be a direct RPC call or detailed client-side inserts.
  int get _branchId => int.tryParse(dotenv.env['BRANCH_ID'] ?? '') ?? 0;

  /// Submit a new order via Edge Function
  Future<void> submitSalesOrder({
    required int tableId,
    required int guestCount,
    required List<SalesOrderItemModel> items,
  }) async {
    try {
      final payload = {
        'table_id': tableId,
        'branch_id': _branchId,
        'guest_count': guestCount,
        'items': items
            .map(
              (e) => {
                'item_barcode': e.itemBarcode,
                'quantity': e.quantity,
                'amount': e.amount,
                'item_modifiers': e.itemModifiers,
                'is_disc_exempt': e.isDiscExempt,
                'item_discount': e.itemDiscount,
              },
            )
            .toList(),
      };

      await _client.functions.invoke('submit-sales-order', body: payload);
    } catch (e) {
      throw Exception('Failed to create order: $e');
    }
  }

  /// Subscribe to order updates for a specific table or all orders
  /// Useful for the Order Summary screen.
  /// Subscribe to order updates for a specific table or all orders
  /// Useful for the Order Summary screen.
  Stream<List<Map<String, dynamic>>> subscribeToOrderUpdates({int? tableId}) {
    final builder = _client.from('sales_order').stream(primaryKey: ['id']);

    if (tableId != null) {
      return builder.eq('table_id', tableId).order('created_at', ascending: false);
    }

    return builder.order('created_at', ascending: false);
  }

  /// Fetch active order for a table
  Future<SalesOrderModel?> getActiveOrder({required int tableId}) async {
    try {
      // 1. Fetch the sales order first
      final orderResponse = await _client
          .from('sales_order')
          .select()
          .eq('table_id', tableId)
          .eq('payment_status', 0) // Active orders only
          .maybeSingle();

      if (orderResponse == null) return null;

      // 2. Fetch the items for this order using the order's ID
      final orderId = orderResponse['sales_order_id'];
      final itemsResponse = await _client.from('sales_order_item').select().eq('sales_order_id', orderId);

      // 3. Manually combine them
      // We need to cast the response to Mutable Map to add the items key
      final orderData = Map<String, dynamic>.from(orderResponse);
      orderData['sales_order_item'] = itemsResponse;

      return SalesOrderModel.fromJson(orderData);
    } catch (e) {
      // Handle error or return null
      print('Error fetching active order: $e');
      return null;
    }
  }

  Future<List<SalesOrderModel>> getOrders({int? tableId}) async {
    // Note: This function originally joined items. Without FK, we can't do simple joins.
    // Use manual fetching if needed, but for now we'll fetch orders without items
    // or implement loop fetching if strictly required (beware N+1).
    // Given the context, getActiveOrder is the critical path.
    // Simplest approach: Fetch orders, then for each, fetch items.

    var query = _client.from('sales_order').select();

    if (tableId != null) {
      query = query.eq('table_id', tableId);
    }

    final response = await query.order('created_at', ascending: false);
    final orders = List<Map<String, dynamic>>.from(response as List);

    // Fetch items for each order (Batching would be better but keeping it simple for now)
    for (var order in orders) {
      final items = await _client.from('sales_order_item').select().eq('sales_order_id', order['sales_order_id']);
      order['sales_order_item'] = items;
    }

    return orders.map((e) => SalesOrderModel.fromJson(e)).toList();
  }
}
