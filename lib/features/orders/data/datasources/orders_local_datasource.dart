import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/config/app_config.dart';
import '../models/sales_order_model.dart';
import '../models/sales_order_item_model.dart';
import 'orders_data_source.dart';

/// Local (self-hosted) orders backend targeting the local_supabase_migration
/// schema: header `sales_order_2`, lines `sales_order_item`, ownership stamped
/// with `pos_client_id`. There is no pending stage — lines are written directly
/// to `sales_order_item` and always read back as "Accepted".
class LocalOrdersDataSource implements OrdersDataSource {
  final SupabaseClient _client;

  LocalOrdersDataSource(this._client);

  String get _posClientId => AppConfig.posClientId;
  int get _orderType => AppConfig.orderTypeCode;

  /// Find the active header id for a table, or null.
  Future<int?> _activeSalesOrderId(int tableId) async {
    final res = await _client
        .from('sales_order_2')
        .select('sales_order_id')
        .eq('table_id', tableId)
        .or('payment_status.eq.0,payment_status.eq.1')
        .maybeSingle();
    return res == null ? null : (res['sales_order_id'] as num).toInt();
  }

  /// Submit items directly to the sales order (reuse open header or create one).
  @override
  Future<void> submitSalesOrder({
    required int tableId,
    required int guestCount,
    required List<SalesOrderItemModel> items,
  }) async {
    try {
      // 1. Reuse the open header for this table, or insert a new one.
      int? salesOrderId = await _activeSalesOrderId(tableId);

      if (salesOrderId == null) {
        final inserted = await _client
            .from('sales_order_2')
            .insert({
              'pos_client_id': _posClientId,
              'table_id': tableId,
              'guest_count': guestCount,
              'order_type': _orderType,
              'payment_status': 0,
            })
            .select('sales_order_id')
            .single();
        salesOrderId = (inserted['sales_order_id'] as num).toInt();
      }

      // 2. Process and insert/update lines in sales_order_item (no pending stage).
      if (items.isNotEmpty) {
        // One batch id per submission: every line touched by this send shares it
        // so the KDS ingest trigger groups them into a single kitchen card (a
        // later send to the same order becomes a new card). See migration 0028.
        final batchId = const Uuid().v4();

        // Fetch existing items for this order to check for duplicates
        final existingItemsRes = await _client
            .from('sales_order_item')
            .select('order_item_id, item_barcode, quantity, customer_name, web_device_id, special_instructions')
            .eq('sales_order_id', salesOrderId);

        final existingItems = List<Map<String, dynamic>>.from(existingItemsRes);

        final updates = <Future>[];
        final newRows = <Map<String, dynamic>>[];

        for (final item in items) {
          // Merge only into a line from the SAME device — different devices keep
          // separate lines even with the same item/nickname/instructions.
          final matchIndex = existingItems.indexWhere((existing) =>
              existing['item_barcode'] == item.itemBarcode &&
              (existing['customer_name'] ?? '') == item.nickname &&
              (existing['web_device_id'] as String?) == item.webDeviceId &&
              _normalizeInstructions(existing['special_instructions'] as String?) ==
                  _normalizeInstructions(item.specialInstructions));

          if (matchIndex > -1) {
            final validMatch = existingItems[matchIndex];
            final oldQty = (validMatch['quantity'] as num).toDouble();
            final newQty = oldQty + item.quantity;
            final newAmount = newQty * item.amount;

            updates.add(
              _client
                  .from('sales_order_item')
                  .update({
                    'quantity': newQty,
                    'amount': newAmount,
                    // Re-stamp so the newly-ordered delta routes to THIS send's
                    // kitchen card rather than the original submission's.
                    'kds_batch_id': batchId,
                  })
                  .eq('order_item_id', validMatch['order_item_id']),
            );

            // Update local list in case of multiple items of same barcode in one batch
            existingItems[matchIndex]['quantity'] = newQty;
          } else {
            newRows.add({
              'pos_client_id': _posClientId,
              'sales_order_id': salesOrderId,
              'item_barcode': item.itemBarcode,
              'quantity': item.quantity,
              'amount': item.amount * item.quantity,
              'item_modifiers': item.itemModifiers,
              'is_disc_exempt': item.isDiscExempt,
              'item_discount': item.itemDiscount,
              'customer_name': item.nickname,
              'web_device_id': item.webDeviceId,
              'special_instructions': item.specialInstructions,
              'kds_batch_id': batchId,
            });
          }
        }

        if (updates.isNotEmpty) {
          await Future.wait(updates);
        }

        if (newRows.isNotEmpty) {
          await _client.from('sales_order_item').insert(newRows);
        }
      }
    } catch (e) {
      throw Exception('Failed to create order: $e');
    }
  }

  /// Update payment status directly on the header.
  @override
  Future<void> updatePaymentStatus({
    required int tableId,
    required int status,
    int? salesOrderId,
  }) async {
    try {
      final query = _client.from('sales_order_2').update({'payment_status': status});
      if (salesOrderId != null) {
        await query.eq('sales_order_id', salesOrderId);
      } else {
        await query.eq('table_id', tableId).or('payment_status.eq.0,payment_status.eq.1');
      }
    } catch (e) {
      throw Exception('Failed to update payment status: $e');
    }
  }

  @override
  Stream<List<Map<String, dynamic>>> subscribeToOrderUpdates({int? tableId}) {
    final builder = _client.from('sales_order_2').stream(primaryKey: ['sales_order_id']);

    if (tableId != null) {
      return builder.eq('table_id', tableId).order('created_at', ascending: false);
    }

    return builder.order('created_at', ascending: false);
  }

  @override
  Stream<void> subscribeToActiveOrderChanges(int salesOrderSupabaseId, int salesOrderId) {
    // Local ids are unified (header id == sales_order_id); there is no pending table.
    final orderStream = _client
        .from('sales_order_2')
        .stream(primaryKey: ['sales_order_id'])
        .eq('sales_order_id', salesOrderId);

    final itemStream = _client
        .from('sales_order_item')
        .stream(primaryKey: ['order_item_id'])
        .eq('sales_order_id', salesOrderId);

    return MergeStream([orderStream, itemStream]);
  }

  @override
  Future<SalesOrderModel?> getActiveOrder({required int tableId, String? deviceId}) async {
    try {
      final activeOrderRes = await _client
          .from('sales_order_2')
          .select()
          .eq('table_id', tableId)
          .or('payment_status.eq.0,payment_status.eq.1')
          .maybeSingle();

      if (activeOrderRes == null) return null;

      final finalOrderData = _mapHeader(activeOrderRes);
      final orderId = finalOrderData['sales_order_id'];

      // Line items scoped to the current ordering device. Rows with a NULL
      // web_device_id (POS/waiter-added or pre-device legacy) are intentionally
      // excluded so a guest sees only their own items.
      var itemQuery = _client.from('sales_order_item').select().eq('sales_order_id', orderId);
      if (deviceId != null) {
        itemQuery = itemQuery.eq('web_device_id', deviceId);
      }
      final items = await itemQuery;
      finalOrderData['sales_order_item'] = items.map(_mapItem).toList();

      return SalesOrderModel.fromJson(finalOrderData);
    } catch (e) {
      print('Error fetching active order: $e');
      return null;
    }
  }

  @override
  Future<List<SalesOrderModel>> getOrders({int? tableId}) async {
    var query = _client.from('sales_order_2').select();

    if (tableId != null) {
      query = query.eq('table_id', tableId);
    }

    final response = await query.order('created_at', ascending: false);
    final orders = List<Map<String, dynamic>>.from(response as List);

    final result = <SalesOrderModel>[];
    for (var order in orders) {
      final mapped = _mapHeader(order);
      final items = await _client.from('sales_order_item').select().eq('sales_order_id', mapped['sales_order_id']);
      mapped['sales_order_item'] = items.map(_mapItem).toList();
      result.add(SalesOrderModel.fromJson(mapped));
    }
    return result;
  }

  /// Local schema has no customer table — nickname is an online-only concept.
  @override
  Future<String?> getNicknameByDeviceId(String deviceId) async => null;

  @override
  Future<void> upsertCustomer(String deviceId, String nickname) async {
    // No-op in local mode.
  }

  /// Map a `sales_order_2` row to the JSON shape `SalesOrderModel` expects.
  /// `id` is required non-null by the model and used by CartBloc for the
  /// realtime subscription, so mirror it from `sales_order_id`.
  Map<String, dynamic> _mapHeader(Map<String, dynamic> row) {
    final data = Map<String, dynamic>.from(row);
    data['id'] = (row['sales_order_id'] as num).toInt();
    return data;
  }

  /// Map a `sales_order_item` row to the JSON shape `SalesOrderItemModel`
  /// expects. Coerce NUMERIC quantity to int and tag as Accepted (no pending).
  Map<String, dynamic> _mapItem(Map<String, dynamic> row) {
    final item = Map<String, dynamic>.from(row);
    final quantity = (row['quantity'] as num).toInt();
    final amount = (row['amount'] as num).toDouble();
    item['quantity'] = quantity;
    item['amount'] = quantity > 0 ? (amount / quantity) : amount;
    item['item_barcode'] = row['item_barcode'] ?? '';
    item['status'] = 'Accepted';
    item['nickname'] = row['customer_name'] ?? '';
    return item;
  }
}

/// Canonical string form of a special-instructions JSON payload so two order
/// lines are treated as "same instructions" only when their answers match
/// (groups sorted by id, choices sorted). Null/empty both normalize to ''.
String _normalizeInstructions(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return raw;
    final groups = decoded.map((g) {
      final m = Map<String, dynamic>.from(g as Map);
      final choices = (m['choices'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
      choices.sort();
      return {
        'group_id': m['group_id'],
        'choices': choices,
        'free_text': (m['free_text'] as String?)?.trim() ?? '',
      };
    }).toList()
      ..sort((a, b) => '${a['group_id']}'.compareTo('${b['group_id']}'));
    return jsonEncode(groups);
  } catch (_) {
    return raw;
  }
}
