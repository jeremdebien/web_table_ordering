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
      final response = await _client
          .from('sales_order')
          .select('*, sales_order_item(*)') // Join with items
          .eq('table_id', tableId)
          .eq('payment_status', 0) // Active orders only
          .maybeSingle();

      if (response == null) return null;
      return SalesOrderModel.fromJson(response);
    } catch (e) {
      // Handle error or return null
      // For now rethrow or print
      print('Error fetching active order: $e');
      return null;
    }
  }

  // Keeping generic getOrders if needed, but updated to tableId
  Future<List<SalesOrderModel>> getOrders({int? tableId}) async {
    var query = _client.from('sales_order').select('*, sales_order_item(*)');

    if (tableId != null) {
      query = query.eq('table_id', tableId);
    }

    final response = await query.order('created_at', ascending: false);
    return (response as List).map((e) => SalesOrderModel.fromJson(e)).toList();
  }
}
