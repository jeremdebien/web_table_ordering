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
