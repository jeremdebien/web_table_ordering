// MIRROR of kwikpos_lite lib/modules/table_layout/presentation/widgets/layout_element_widget.dart.
// Keep both copies in sync so the web floor plan renders like the POS.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:web_table_ordering/features/table/data/models/layout_item_model.dart';

/// Blueprint element types styled through [LayoutItemModel.props] (migration
/// 0069), rendered by [LayoutElementWidget] in the editor and on the POS.
const String kLayoutText = 'text';
const String kLayoutArea = 'area';
const String kLayoutMarker = 'marker';

bool isLayoutElementType(String type) => type == kLayoutText || type == kLayoutArea || type == kLayoutMarker;

/// Theme-safe colour presets (light, dark). Stored by key so a colour stays
/// readable in both themes instead of persisting a raw ARGB value.
const Map<String, (Color, Color)> layoutColorPresets = {
  'default': (Color(0xFF1E293B), Color(0xFFE2E8F0)),
  'red': (Color(0xFFDC2626), Color(0xFFF87171)),
  'orange': (Color(0xFFEA580C), Color(0xFFFB923C)),
  'green': (Color(0xFF16A34A), Color(0xFF4ADE80)),
  'blue': (Color(0xFF2563EB), Color(0xFF60A5FA)),
  'purple': (Color(0xFF7C3AED), Color(0xFFA78BFA)),
  'grey': (Color(0xFF64748B), Color(0xFF94A3B8)),
};

Color layoutColor(String key, bool isDark) {
  final pair = layoutColorPresets[key] ?? layoutColorPresets['default']!;
  return isDark ? pair.$2 : pair.$1;
}

/// Marker icons: key → (icon, default caption).
const Map<String, (IconData, String)> layoutMarkerIcons = {
  'restroom': (Icons.wc_rounded, 'Restroom'),
  'kitchen': (Icons.soup_kitchen_outlined, 'Kitchen'),
  'bar': (Icons.local_bar_rounded, 'Bar'),
  'entrance': (Icons.login_rounded, 'Entrance'),
  'exit': (Icons.logout_rounded, 'Exit'),
  'stairs': (Icons.stairs_outlined, 'Stairs'),
  'stage': (Icons.mic_rounded, 'Stage'),
  'pay': (Icons.payments_outlined, 'Pay Here'),
  'smoking': (Icons.smoking_rooms_rounded, 'Smoking'),
  'kids': (Icons.child_care_rounded, 'Kids'),
  'ac': (Icons.ac_unit_rounded, 'Aircon'),
  'info': (Icons.info_outline_rounded, 'Info'),
};

/// Typed view over [LayoutItemModel.props] with defaults applied.
class LayoutItemStyle {
  final double fontSize;
  final bool bold;
  final bool italic;
  final String color;
  final String align; // left | center | right
  final bool background; // text only
  final String fill; // area only
  final String icon; // marker only

  const LayoutItemStyle({
    this.fontSize = 14,
    this.bold = false,
    this.italic = false,
    this.color = 'default',
    this.align = 'center',
    this.background = false,
    this.fill = 'blue',
    this.icon = 'restroom',
  });

  factory LayoutItemStyle.fromProps(Map<String, dynamic> p) {
    const d = LayoutItemStyle();
    return LayoutItemStyle(
      fontSize: (p['fontSize'] as num?)?.toDouble() ?? d.fontSize,
      bold: p['bold'] == true,
      italic: p['italic'] == true,
      color: p['color'] as String? ?? d.color,
      align: p['align'] as String? ?? d.align,
      background: p['bg'] == true,
      fill: p['fill'] as String? ?? d.fill,
      icon: p['icon'] as String? ?? d.icon,
    );
  }

  Map<String, dynamic> toProps(String type) => {
        'fontSize': fontSize,
        'bold': bold,
        'italic': italic,
        'color': color,
        'align': align,
        if (type == kLayoutText) 'bg': background,
        if (type == kLayoutArea) 'fill': fill,
        if (type == kLayoutMarker) 'icon': icon,
      };

  LayoutItemStyle copyWith({
    double? fontSize,
    bool? bold,
    bool? italic,
    String? color,
    String? align,
    bool? background,
    String? fill,
    String? icon,
  }) =>
      LayoutItemStyle(
        fontSize: fontSize ?? this.fontSize,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        color: color ?? this.color,
        align: align ?? this.align,
        background: background ?? this.background,
        fill: fill ?? this.fill,
        icon: icon ?? this.icon,
      );

  TextAlign get textAlign => switch (align) {
        'left' => TextAlign.left,
        'right' => TextAlign.right,
        _ => TextAlign.center,
      };

  Alignment get boxAlignment => switch (align) {
        'left' => Alignment.centerLeft,
        'right' => Alignment.centerRight,
        _ => Alignment.center,
      };

  TextStyle textStyle(bool isDark) => TextStyle(
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        color: layoutColor(color, isDark),
        height: 1.15,
      );
}

/// Renders a text / area / marker element filling its item box.
class LayoutElementWidget extends StatelessWidget {
  final LayoutItemModel item;
  final bool isSelected;
  final bool isDark;

  const LayoutElementWidget({super.key, required this.item, required this.isDark, this.isSelected = false});

  @override
  Widget build(BuildContext context) {
    final style = LayoutItemStyle.fromProps(item.props);
    return switch (item.type) {
      kLayoutArea => _area(style),
      kLayoutMarker => _marker(style),
      _ => _text(style),
    };
  }

  Widget _text(LayoutItemStyle style) {
    final color = layoutColor(style.color, isDark);
    Widget label = Text(item.description, textAlign: style.textAlign, style: style.textStyle(isDark));
    if (style.background) {
      label = Container(
        padding: EdgeInsets.symmetric(horizontal: style.fontSize * 0.6, vertical: style.fontSize * 0.25),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: label,
      );
    }
    return Align(
      alignment: style.boxAlignment,
      // Shrinks (never grows) the text to fit the resizable box.
      child: FittedBox(fit: BoxFit.scaleDown, alignment: style.boxAlignment, child: label),
    );
  }

  Widget _area(LayoutItemStyle style) {
    final fill = layoutColor(style.fill, isDark);
    return Container(
      decoration: BoxDecoration(
        color: fill.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fill.withValues(alpha: 0.6), width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      alignment: switch (style.align) {
        'right' => Alignment.topRight,
        'center' => Alignment.topCenter,
        _ => Alignment.topLeft,
      },
      child: item.description.isEmpty
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(item.description, textAlign: style.textAlign, style: style.textStyle(isDark)),
            ),
    );
  }

  Widget _marker(LayoutItemStyle style) {
    final color = layoutColor(style.color, isDark);
    final icon = (layoutMarkerIcons[style.icon] ?? layoutMarkerIcons['info']!).$1;
    return LayoutBuilder(builder: (context, c) {
      final side = math.min(c.maxWidth, c.maxHeight);
      final hasCaption = item.description.isNotEmpty;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: side * (hasCaption ? 0.55 : 0.8), color: color),
          if (hasCaption)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(item.description, textAlign: TextAlign.center, style: style.textStyle(isDark)),
              ),
            ),
        ],
      );
    });
  }
}
