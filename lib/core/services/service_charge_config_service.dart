import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Service-charge setup, read from the POS's singleton `service_charge` row
/// (id = 1, consolidator migration 0033). Mirrors kwikpos_lite
/// `ServiceChargeConfig`.
class ServiceChargeConfig {
  /// Percent, e.g. 10 for 10%.
  final double rate;
  final bool active;

  /// true = computed on the pre-discount base.
  final bool beforeDiscount;

  /// true = VAT is stripped from the base before applying the percent.
  final bool removeVat;

  const ServiceChargeConfig({
    required this.rate,
    required this.active,
    required this.beforeDiscount,
    required this.removeVat,
  });

  /// What the web app always charged before this config was read: a flat 10%
  /// of the subtotal. Kept for online mode, which has no `service_charge` table.
  static const legacy = ServiceChargeConfig(rate: 10, active: true, beforeDiscount: false, removeVat: false);

  static const none = ServiceChargeConfig(rate: 0, active: false, beforeDiscount: false, removeVat: false);

  /// Rate to apply (0 when inactive).
  double get effectiveRate => active ? rate : 0;

  /// The POS's VAT rate is a terminal-local preference (`vatRate`, default 12%)
  /// that is not synced to the consolidator, so the web uses the POS default.
  static const double vatRate = 0.12;

  /// Port of kwikpos_lite `ServiceChargeHelper.computeServiceCharge`. The web
  /// never applies discounts, so [discountAmount] and VAT privilege default to
  /// 0 — the POS's math reduces to `base × rate`, where base is the subtotal,
  /// VAT-stripped when [removeVat].
  double compute(double grossEligibleBase, {double discountAmount = 0}) {
    final percent = effectiveRate;
    if (percent == 0) return 0;
    double base;
    if (beforeDiscount) {
      base = removeVat ? grossEligibleBase / (1 + vatRate) : grossEligibleBase;
    } else {
      var remaining = grossEligibleBase - discountAmount;
      if (remaining < 0) remaining = 0;
      base = removeVat ? remaining / (1 + vatRate) : remaining;
    }
    if (base < 0) base = 0;
    return _round2(base * (percent / 100));
  }

  /// "10%" / "12.5%" for the summary label.
  String get rateLabel => rate % 1 == 0 ? '${rate.toInt()}%' : '${rate.toStringAsFixed(2)}%';

  // POS DecimalFormatterHelper.formatDouble: round half-up to 2 decimals after
  // shaving binary float noise.
  static double _round2(double v) {
    if (v.isNaN || v.isInfinite) return 0;
    return ((v * 100) + 1e-9).round() / 100;
  }

  static bool _asBool(dynamic v) => v == true || v == 1 || v == '1';

  factory ServiceChargeConfig.fromRow(Map<String, dynamic> row) => ServiceChargeConfig(
        rate: (row['serviceChargeAmt'] as num?)?.toDouble() ?? 0,
        active: row['status'] == 1 || row['status'] == true,
        beforeDiscount: _asBool(row['sc_before_discount']),
        removeVat: _asBool(row['sc_vat_exclusive']),
      );
}

class ServiceChargeConfigService {
  ServiceChargeConfigService(this._client);

  final SupabaseClient _client;

  /// The POS row, or [ServiceChargeConfig.none] when there is no row (no
  /// service charge configured). Unreadable (online mode / offline) →
  /// [ServiceChargeConfig.legacy], the old flat 10%.
  Future<ServiceChargeConfig> load() async {
    try {
      final row = await _client.from('service_charge').select().eq('id', 1).maybeSingle();
      return row == null ? ServiceChargeConfig.none : ServiceChargeConfig.fromRow(row);
    } catch (e) {
      debugPrint('ServiceChargeConfigService read failed: $e');
      return ServiceChargeConfig.legacy;
    }
  }
}
