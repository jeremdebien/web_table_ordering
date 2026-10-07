/// Port of the POS item scheduling rules
/// (`kwikpos_lite/lib/modules/items/models/item_availability.dart`), so the web
/// menu greys out exactly what the POS does. Keep [isAvailable] and
/// [checkAvailability] in sync with that file.
///
/// Rows come from the consolidator `item_availability` table (migration 0013);
/// holidays from `holidays` (0009).
///
/// Evaluated with the guest device's clock, whereas the POS uses the
/// terminal's. Fine for guests ordering on site.
library;

/// How a rule behaves on a holiday. Stored in `available_on_holiday` by index:
///   * [suppressed]     (0): the rule is inactive on holidays.
///   * [normal]         (1): a holiday is an ordinary day (default).
///   * [forceAvailable] (2): on a holiday the weekday + week-of-month gate is
///                           bypassed; time-of-day and date range still apply.
enum HolidayMode { suppressed, normal, forceAvailable }

class ItemAvailabilityRule {
  final String itemBarcode;
  final String? day;
  final String? startTime;
  final String? endTime;
  final String? dateStart;
  final String? dateEnd;
  final String? weekOfMonth;
  final bool isActive;
  final HolidayMode holidayMode;

  const ItemAvailabilityRule({
    required this.itemBarcode,
    this.day,
    this.startTime,
    this.endTime,
    this.dateStart,
    this.dateEnd,
    this.weekOfMonth,
    this.isActive = true,
    this.holidayMode = HolidayMode.normal,
  });

  factory ItemAvailabilityRule.fromJson(Map<String, dynamic> json) {
    return ItemAvailabilityRule(
      itemBarcode: json['item_barcode'] as String,
      day: json['day'] as String?,
      startTime: json['start_time'] as String?,
      endTime: json['end_time'] as String?,
      dateStart: json['date_start'] as String?,
      dateEnd: json['date_end'] as String?,
      weekOfMonth: json['week_of_month'] as String?,
      isActive: json['is_active'] == 1 || json['is_active'] == true,
      holidayMode: _holidayModeFromValue(json['available_on_holiday']),
    );
  }

  // 0=suppressed, 1=normal, 2=force-available. Null or out-of-range => normal.
  static HolidayMode _holidayModeFromValue(dynamic value) {
    final index = value is num ? value.toInt() : 1;
    if (index < 0 || index >= HolidayMode.values.length) return HolidayMode.normal;
    return HolidayMode.values[index];
  }

  // Same names as the POS's DateFormat('EEEE') in the default (en) locale.
  static const _weekdayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool isAvailable(DateTime now, {bool isHoliday = false}) {
    if (!isActive) return false;

    // Suppressed rules drop out entirely on a holiday.
    if (isHoliday && holidayMode == HolidayMode.suppressed) return false;

    // Force-available rules ignore the weekday / week-of-month gate on a
    // holiday; time and date range still restrict them.
    final bypassDayGate = isHoliday && holidayMode == HolidayMode.forceAvailable;

    // Date range
    if (dateStart != null && dateStart!.isNotEmpty) {
      final start = DateTime.parse(dateStart!);
      if (now.isBefore(DateTime(start.year, start.month, start.day))) return false;
    }
    if (dateEnd != null && dateEnd!.isNotEmpty) {
      final end = DateTime.parse(dateEnd!);
      if (now.isAfter(DateTime(end.year, end.month, end.day, 23, 59, 59))) return false;
    }

    // Day of week
    if (!bypassDayGate && day != null && day!.isNotEmpty) {
      if (day != _weekdayNames[now.weekday - 1]) return false;
    }

    // Time range
    if (startTime != null && startTime!.isNotEmpty && endTime != null && endTime!.isNotEmpty) {
      final currentMinutes = now.hour * 60 + now.minute;

      final startParts = startTime!.split(':');
      final startMinutes = int.parse(startParts[0]) * 60 + int.parse(startParts[1]);

      final endParts = endTime!.split(':');
      final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);

      // A range whose end is before its start wraps past midnight.
      final inRange = startMinutes <= endMinutes
          ? currentMinutes >= startMinutes && currentMinutes <= endMinutes
          : currentMinutes >= startMinutes || currentMinutes <= endMinutes;
      if (!inRange) return false;
    }

    // Week of month
    if (!bypassDayGate && weekOfMonth != null && weekOfMonth!.isNotEmpty) {
      final weeks = weekOfMonth!.split(',');
      final currentWeekNum = (now.day - 1) ~/ 7 + 1;

      var isMatch = weeks.contains(currentWeekNum.toString());

      if (!isMatch && weeks.contains('L')) {
        // Last occurrence of this weekday in the month.
        final nextWeekSameDay = now.add(const Duration(days: 7));
        if (nextWeekSameDay.month != now.month) isMatch = true;
      }

      if (!isMatch) return false;
    }

    return true;
  }

  static bool checkAvailability(List<ItemAvailabilityRule> rules, DateTime now,
      {List<String> holidayDates = const []}) {
    if (rules.isEmpty) return true; // Always available if no rules
    final isHoliday = holidayDates.contains(_ymd(now));
    return rules.any((rule) => rule.isAvailable(now, isHoliday: isHoliday));
  }
}
