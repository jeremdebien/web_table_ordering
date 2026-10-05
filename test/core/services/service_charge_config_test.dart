import 'package:flutter_test/flutter_test.dart';
import 'package:web_table_ordering/core/services/service_charge_config_service.dart';

void main() {
  group('ServiceChargeConfig.compute (POS ServiceChargeHelper port)', () {
    test('VAT-exclusive: strips 12% VAT before applying the rate', () {
      final c = ServiceChargeConfig.fromRow(
          {'serviceChargeAmt': 10, 'status': 1, 'sc_before_discount': 0, 'sc_vat_exclusive': 1});
      // 1120 / 1.12 = 1000 → 10% = 100
      expect(c.compute(1120), 100);
      expect(c.compute(350), 31.25);
    });

    test('VAT-inclusive: rate on the gross subtotal', () {
      final c = ServiceChargeConfig.fromRow({'serviceChargeAmt': 10, 'status': 1, 'sc_vat_exclusive': 0});
      expect(c.compute(1120), 112);
    });

    test('inactive or zero rate charges nothing', () {
      expect(ServiceChargeConfig.fromRow({'serviceChargeAmt': 10, 'status': 0}).compute(1000), 0);
      expect(ServiceChargeConfig.none.compute(1000), 0);
    });

    test('rounds half-up to 2 decimals like the POS', () {
      final c = ServiceChargeConfig.fromRow({'serviceChargeAmt': 10, 'status': 1, 'sc_vat_exclusive': 1});
      // 100 / 1.12 * 0.10 = 8.928571… → 8.93
      expect(c.compute(100), 8.93);
    });

    test('legacy fallback keeps the old flat 10%', () {
      expect(ServiceChargeConfig.legacy.compute(1000), 100);
      expect(ServiceChargeConfig.legacy.rateLabel, '10%');
    });
  });
}
