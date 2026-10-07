import 'package:flutter_test/flutter_test.dart';
import 'package:web_table_ordering/features/orders/data/models/line_customization.dart';
import 'package:web_table_ordering/features/orders/data/models/sales_order_item_model.dart';

void main() {
  const egg = CustomizationPick(productBarcode: 'EGG', productName: 'Egg', price: 20, quantity: 2);
  const nori = CustomizationPick(productBarcode: 'NORI', productName: 'Nori');

  group('LineCustomization', () {
    test('encode writes the POS ProductOrder shape plus a KDS barcode key', () {
      final json = LineCustomization.encode({
        'Add-ons': [egg],
        'Empty': [],
      })!;
      final decoded = LineCustomization.decode(json);
      expect(decoded.keys, ['Add-ons']);
      expect(json, contains('"productBarcode":"EGG"'));
      expect(json, contains('"barcode":"EGG"'));
      expect(decoded['Add-ons']!.single.quantity, 2);
    });

    test('encode returns null when nothing picked', () {
      expect(LineCustomization.encode({'A': []}), isNull);
    });

    test('decode tolerates POS-written JSON without the barcode key and bad input', () {
      final picks = LineCustomization.decode(
          '{"Size":[{"productBarcode":"X","productName":"Large","price":5,"quantity":1,"orderTypeCode":1}]}');
      expect(picks['Size']!.single.productBarcode, 'X');
      expect(LineCustomization.decode('not json'), isEmpty);
      expect(LineCustomization.decode(null), isEmpty);
    });

    test('unitDelta sums price × quantity', () {
      expect(LineCustomization.unitDelta({'A': [egg, nori]}), 40);
    });

    test('fingerprint ignores pick order and differs by picks', () {
      final a = LineCustomization.encode({'A': [egg, nori]});
      final b = LineCustomization.encode({'A': [nori, egg]});
      final c = LineCustomization.encode({'A': [nori]});
      expect(LineCustomization.fingerprint(a), LineCustomization.fingerprint(b));
      expect(LineCustomization.fingerprint(a), isNot(LineCustomization.fingerprint(c)));
      expect(LineCustomization.fingerprint(null), '');
    });

    test('displayLines shows counts and priced totals', () {
      final lines = LineCustomization.displayLines(LineCustomization.encode({'Add-ons': [egg, nori]}));
      expect(lines.single, 'Add-ons: 2x Egg (+₱40), Nori');
    });
  });

  test('SalesOrderItemModel round-trips customization and base_variant_barcode', () {
    final model = SalesOrderItemModel.fromJson({
      'item_barcode': 'RAMEN-L',
      'item_name': 'Ramen Large',
      'quantity': 1,
      'amount': 300.0,
      'customization': LineCustomization.encode({'Add-ons': [egg]}),
      'base_variant_barcode': 'RAMEN',
    });
    expect(model.itemName, 'Ramen Large');
    expect(model.baseVariantBarcode, 'RAMEN');
    final json = model.toJson();
    expect(json['base_variant_barcode'], 'RAMEN');
    expect(LineCustomization.decode(json['customization'] as String)['Add-ons']!.single.productBarcode, 'EGG');
  });
}
