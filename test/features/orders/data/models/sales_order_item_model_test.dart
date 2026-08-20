import 'package:flutter_test/flutter_test.dart';
import 'package:web_table_ordering/features/orders/data/models/sales_order_item_model.dart';

void main() {
  group('SalesOrderItemModel', () {
    test('should properly serialize and deserialize note field', () {
      final json = {
        'order_item_id': 101,
        'sales_order_id': 202,
        'item_barcode': 'BC123',
        'quantity': 2,
        'amount': 150.0,
        'is_disc_exempt': 0,
        'customer_name': 'Alice',
        'special_instructions': '[{"group_id":1,"label":"Spice","choices":["Mild"],"free_text":null}]',
        'note': 'Extra gravy on the side please',
        'status': 'Accepted',
      };

      final model = SalesOrderItemModel.fromJson(json);

      expect(model.orderItemId, 101);
      expect(model.salesOrderId, 202);
      expect(model.itemBarcode, 'BC123');
      expect(model.quantity, 2);
      expect(model.amount, 150.0);
      expect(model.specialInstructions, isNotNull);
      expect(model.note, 'Extra gravy on the side please');

      final serialized = model.toJson();
      expect(serialized['note'], 'Extra gravy on the side please');
      expect(serialized['special_instructions'], model.specialInstructions);
    });

    test('copyWith should update note correctly', () {
      final model = SalesOrderItemModel(
        itemBarcode: 'BC123',
        quantity: 1,
        amount: 100.0,
        note: 'Initial note',
      );

      final updated = model.copyWith(note: 'Updated note');
      expect(updated.note, 'Updated note');
      expect(updated.itemBarcode, 'BC123');
    });
  });
}
