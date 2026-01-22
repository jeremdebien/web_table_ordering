import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:rxdart/rxdart.dart';
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

      await _client.functions.invoke('submit-sales-order-2', body: payload);
    } catch (e) {
      throw Exception('Failed to create order: $e');
    }
  }

  /// Update payment status via Edge Function
  Future<void> updatePaymentStatus({
    required int tableId,
    required int status,
    int? salesOrderId,
  }) async {
    try {
      final payload = {
        'table_id': tableId,
        'payment_status': status,
        if (salesOrderId != null) 'sales_order_id': salesOrderId,
      };

      await _client.functions.invoke('update_payment_status', body: payload);
    } catch (e) {
      throw Exception('Failed to update payment status: $e');
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

  /// Subscribe to realtime changes for a specific sales order and its items
  Stream<void> subscribeToActiveOrderChanges(int salesOrderSupabaseId, int salesOrderId) {
    final orderStream = _client.from('sales_order').stream(primaryKey: ['id']).eq('id', salesOrderSupabaseId);

    final itemStream = _client.from('sales_order_item').stream(primaryKey: ['id']).eq('sales_order_id', salesOrderId);

    final pendingItemStream = _client
        .from('sales_order_item_pending')
        .stream(primaryKey: ['id'])
        .eq('sales_order_id', salesOrderId);

    return MergeStream([orderStream, itemStream, pendingItemStream]);
  }

  /// Fetch active order for a table
  Future<SalesOrderModel?> getActiveOrder({required int tableId}) async {
    try {
      // 1. Fetch active sales_order
      final activeOrderRes = await _client
          .from('sales_order')
          .select()
          .eq('table_id', tableId)
          .or('payment_status.eq.0,payment_status.eq.1') // Active or Bill Requested orders
          .maybeSingle();

      if (activeOrderRes == null) return null;

      final orderId = activeOrderRes['sales_order_id'] ?? activeOrderRes['id'];
      Map<String, dynamic> finalOrderData = Map<String, dynamic>.from(activeOrderRes);
      List<Map<String, dynamic>> combinedItems = [];

      // 2. Fetch Accepted Items
      final activeItems = await _client.from('sales_order_item').select().eq('sales_order_id', orderId);

      for (var item in activeItems) {
        final mutableItem = Map<String, dynamic>.from(item);
        mutableItem['status'] = 'Accepted';
        combinedItems.add(mutableItem);
      }

      // 3. Fetch Pending Items
      final pendingItems = await _client.from('sales_order_item_pending').select().eq('sales_order_id', orderId);

      for (var item in pendingItems) {
        final mutableItem = Map<String, dynamic>.from(item);
        final isCancelled = item['is_cancelled'] == true; // Handle null/bool
        mutableItem['status'] = isCancelled ? 'Cancelled' : 'Pending';
        combinedItems.add(mutableItem);
      }

      finalOrderData['sales_order_item'] = combinedItems;

      return SalesOrderModel.fromJson(finalOrderData);
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
