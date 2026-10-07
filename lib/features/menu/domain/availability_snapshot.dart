import 'package:equatable/equatable.dart';

import '../data/models/item_model.dart';
import 'item_availability_rule.dart';

/// The POS scheduling rules and holidays loaded with the menu. Schedule state
/// depends on the time, so it is evaluated on demand ([isScheduledAt]) rather
/// than stored on the item.
class AvailabilitySnapshot extends Equatable {
  final Map<String, List<ItemAvailabilityRule>> rulesByBarcode;
  final List<String> holidayDates;

  const AvailabilitySnapshot({this.rulesByBarcode = const {}, this.holidayDates = const []});

  static const empty = AvailabilitySnapshot();

  factory AvailabilitySnapshot.fromRules(List<ItemAvailabilityRule> rules, List<String> holidayDates) {
    final byBarcode = <String, List<ItemAvailabilityRule>>{};
    for (final rule in rules) {
      byBarcode.putIfAbsent(rule.itemBarcode, () => []).add(rule);
    }
    return AvailabilitySnapshot(rulesByBarcode: byBarcode, holidayDates: holidayDates);
  }

  /// Whether the item's schedule allows ordering at [now]. No rules = always.
  bool isScheduledAt(String barcode, DateTime now) => ItemAvailabilityRule.checkAvailability(
        rulesByBarcode[barcode] ?? const [],
        now,
        holidayDates: holidayDates,
      );

  /// Why [item] can't be ordered at [now], or null if it can. Same gates as the
  /// POS grid: sold out first, then the schedule.
  String? unavailableReason(ItemModel item, DateTime now) {
    if (item.isSoldOut) return 'Sold out';
    if (!isScheduledAt(item.barcode, now)) return 'Not available now';
    return null;
  }

  /// Pre-submit check: which of [barcodes] can no longer be ordered at [now].
  /// [current] is a fresh fetch of the still-enabled, non-hidden rows, so a
  /// barcode missing from it was disabled or hidden on the POS meanwhile.
  Set<String> unorderable(Iterable<String> barcodes, Map<String, ItemModel> current, DateTime now) => {
        for (final b in barcodes)
          if (current[b] == null || unavailableReason(current[b]!, now) != null) b,
      };

  @override
  List<Object?> get props => [rulesByBarcode, holidayDates];
}
