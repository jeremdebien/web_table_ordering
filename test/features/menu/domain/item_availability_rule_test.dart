import 'package:flutter_test/flutter_test.dart';
import 'package:web_table_ordering/features/menu/data/models/item_model.dart';
import 'package:web_table_ordering/features/menu/domain/availability_snapshot.dart';
import 'package:web_table_ordering/features/menu/domain/item_availability_rule.dart';

ItemAvailabilityRule rule({
  String? day,
  String? start,
  String? end,
  String? dateStart,
  String? dateEnd,
  String? week,
  bool active = true,
  HolidayMode holiday = HolidayMode.normal,
}) =>
    ItemAvailabilityRule(
      itemBarcode: 'A',
      day: day,
      startTime: start,
      endTime: end,
      dateStart: dateStart,
      dateEnd: dateEnd,
      weekOfMonth: week,
      isActive: active,
      holidayMode: holiday,
    );

ItemModel item(String barcode, {bool soldOut = false}) => ItemModel(
      id: 1,
      barcode: barcode,
      itemCode: barcode,
      name: barcode,
      departmentId: 1,
      categoryId: 1,
      price: 100,
      isSoldOut: soldOut,
      createdAt: DateTime(2026),
    );

void main() {
  // 2026-10-07 is a Wednesday (first Wednesday of the month).
  final wed1200 = DateTime(2026, 10, 7, 12, 0);

  group('ItemAvailabilityRule.checkAvailability', () {
    test('no rules means always available', () {
      expect(ItemAvailabilityRule.checkAvailability([], wed1200), isTrue);
    });

    test('inactive rule never matches', () {
      expect(ItemAvailabilityRule.checkAvailability([rule(active: false)], wed1200), isFalse);
    });

    test('time window, inclusive at both ends', () {
      final r = rule(start: '11:00', end: '14:00');
      expect(r.isAvailable(wed1200), isTrue);
      expect(r.isAvailable(DateTime(2026, 10, 7, 11, 0)), isTrue);
      expect(r.isAvailable(DateTime(2026, 10, 7, 14, 0)), isTrue);
      expect(r.isAvailable(DateTime(2026, 10, 7, 14, 1)), isFalse);
      expect(r.isAvailable(DateTime(2026, 10, 7, 10, 59)), isFalse);
    });

    test('time window wrapping past midnight', () {
      final r = rule(start: '22:00', end: '02:00');
      expect(r.isAvailable(DateTime(2026, 10, 7, 23, 30)), isTrue);
      expect(r.isAvailable(DateTime(2026, 10, 8, 1, 30)), isTrue);
      expect(r.isAvailable(wed1200), isFalse);
    });

    test('day of week', () {
      expect(rule(day: 'Wednesday').isAvailable(wed1200), isTrue);
      expect(rule(day: 'Thursday').isAvailable(wed1200), isFalse);
    });

    test('date range, end date inclusive', () {
      expect(rule(dateStart: '2026-10-07', dateEnd: '2026-10-07').isAvailable(DateTime(2026, 10, 7, 23, 59)), isTrue);
      expect(rule(dateStart: '2026-10-08').isAvailable(wed1200), isFalse);
      expect(rule(dateEnd: '2026-10-06').isAvailable(wed1200), isFalse);
    });

    test('week of month, including last occurrence', () {
      expect(rule(week: '1').isAvailable(wed1200), isTrue);
      expect(rule(week: '2,3').isAvailable(wed1200), isFalse);
      // 2026-10-28 is the last Wednesday of October (5th week falls in Nov).
      expect(rule(week: 'L').isAvailable(DateTime(2026, 10, 28, 12)), isTrue);
      expect(rule(week: 'L').isAvailable(DateTime(2026, 10, 21, 12)), isFalse);
    });

    test('any matching rule makes the item available', () {
      final rules = [rule(day: 'Monday'), rule(day: 'Wednesday')];
      expect(ItemAvailabilityRule.checkAvailability(rules, wed1200), isTrue);
    });

    group('holiday modes', () {
      const holidays = ['2026-10-07'];

      test('suppressed rule is off on a holiday', () {
        final rules = [rule(holiday: HolidayMode.suppressed)];
        expect(ItemAvailabilityRule.checkAvailability(rules, wed1200, holidayDates: holidays), isFalse);
        expect(ItemAvailabilityRule.checkAvailability(rules, wed1200), isTrue);
      });

      test('normal rule keeps its day gate on a holiday', () {
        final rules = [rule(day: 'Monday')];
        expect(ItemAvailabilityRule.checkAvailability(rules, wed1200, holidayDates: holidays), isFalse);
      });

      test('force-available bypasses day and week gates but not time', () {
        final rules = [rule(day: 'Monday', week: '3', start: '11:00', end: '13:00', holiday: HolidayMode.forceAvailable)];
        expect(ItemAvailabilityRule.checkAvailability(rules, wed1200, holidayDates: holidays), isTrue);
        expect(
          ItemAvailabilityRule.checkAvailability(rules, DateTime(2026, 10, 7, 15), holidayDates: holidays),
          isFalse,
        );
      });
    });

    test('fromJson reads POS integer flags', () {
      final r = ItemAvailabilityRule.fromJson({
        'item_barcode': 'A',
        'day': 'Wednesday',
        'is_active': 1,
        'available_on_holiday': 2,
      });
      expect(r.isActive, isTrue);
      expect(r.holidayMode, HolidayMode.forceAvailable);
    });
  });

  group('AvailabilitySnapshot', () {
    final snapshot = AvailabilitySnapshot.fromRules([rule(start: '11:00', end: '14:00')], const []);

    test('unavailableReason: sold out, off schedule, or orderable', () {
      expect(snapshot.unavailableReason(item('A', soldOut: true), wed1200), 'Sold out');
      expect(snapshot.unavailableReason(item('A'), DateTime(2026, 10, 7, 15)), 'Not available now');
      expect(snapshot.unavailableReason(item('A'), wed1200), isNull);
      // No rules for B: always available.
      expect(snapshot.unavailableReason(item('B'), DateTime(2026, 10, 7, 15)), isNull);
    });

    test('unorderable flags missing (disabled/hidden), sold out and off-schedule barcodes', () {
      final current = {'A': item('A'), 'B': item('B', soldOut: true)};
      expect(snapshot.unorderable(['A', 'B', 'C'], current, wed1200), {'B', 'C'});
      expect(snapshot.unorderable(['A'], current, DateTime(2026, 10, 7, 15)), {'A'});
    });
  });

  test('ItemModel reads is_sold_out as BOOLEAN or 0/1', () {
    Map<String, dynamic> json(dynamic v) => {
          'id': 1,
          'barcode': 'A',
          'item_code': 'A',
          'item_name': 'A',
          'department_id': 1,
          'category_id': 1,
          'price': 1,
          'created_at': '2026-01-01T00:00:00',
          'is_sold_out': v,
        };
    expect(ItemModel.fromJson(json(true)).isSoldOut, isTrue);
    expect(ItemModel.fromJson(json(1)).isSoldOut, isTrue);
    expect(ItemModel.fromJson(json(false)).isSoldOut, isFalse);
    expect(ItemModel.fromJson(json(null)).isSoldOut, isFalse);
  });
}
