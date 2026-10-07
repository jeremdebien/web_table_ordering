// MIRROR of kwikpos_lite lib/modules/table_layout/presentation/widgets/architectural_entity_painter.dart.
// Keep both copies in sync so the web floor plan renders like the POS.

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

class ArchitecturalEntityPainter extends CustomPainter {
  final String type;
  final bool isSelected;
  final bool isDark;

  ArchitecturalEntityPainter({
    required this.type,
    required this.isSelected,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    if (type == 'wall') {
      // Divider Wall
      final fillPaint = Paint()
        ..shader = LinearGradient(
          colors: isDark
              ? [const Color(0xFF475569), const Color(0xFF334155)]
              : [const Color(0xFF94A3B8), const Color(0xFF64748B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Rect.fromLTWH(0, 0, w, h));

      final strokePaint = Paint()
        ..color = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      // Draw main solid wall body
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(2));
      canvas.drawRRect(rect, fillPaint);
      canvas.drawRRect(rect, strokePaint);

      // Draw subtle architectural double line inside the wall
      final detailPaint = Paint()
        ..color = (isDark ? Colors.white : Colors.black).withOpacity(0.12)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(0, h * 0.3), Offset(w, h * 0.3), detailPaint);
      canvas.drawLine(Offset(0, h * 0.7), Offset(w, h * 0.7), detailPaint);
    } else if (type == 'door') {
      // Architectural Door with Swing Arc
      final framePaint = Paint()
        ..color = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      final leafPaint = Paint()
        ..color = isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      final swingPaint = Paint()
        ..color = (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)).withOpacity(0.6)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      // 1. Draw door frames on both ends (left and right jambs)
      canvas.drawLine(const Offset(0, 0), Offset(0, h), framePaint);
      canvas.drawLine(Offset(w, 0), Offset(w, h), framePaint);

      // 2. Draw open door slab leaf rotated at 90 degrees or 60 degrees.
      // Let's draw it swinging upwards from the left jamb.
      // Length of leaf matches the door opening width (w)
      final double angleRad = -math.pi / 2.5; // ~72 degrees open
      final double leafX = w * math.cos(angleRad);
      final double leafY = h / 2 + w * math.sin(angleRad);

      canvas.drawLine(Offset(0, h / 2), Offset(leafX, leafY), leafPaint);

      // 3. Draw dotted/dashed swing arc sweep
      // We draw an arc from the leaf's open tip back to the opposite wall frame (w, h / 2)
      final Path path = Path();
      path.moveTo(leafX, leafY);

      // Sweep arc to (w, h / 2) centered at hinge (0, h / 2)
      final rect = Rect.fromCircle(center: Offset(0, h / 2), radius: w);
      path.arcTo(rect, angleRad, -angleRad, false);

      // Draw path with dashed pattern manually
      final Path dashPath = _buildDashedPath(path, 4.0, 3.0);
      canvas.drawPath(dashPath, swingPaint);
    } else if (type == 'fill') {
      // Outside Void Space / solid mask fill
      final fillPaint = Paint()
        ..color = isDark ? const Color(0xFF111827) : const Color(0xFFE2E8F0)
        ..style = PaintingStyle.fill;

      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), fillPaint);

      // Draw premium structural cross-hatch diagonal stripes inside the void block
      // final stripePaint = Paint()
      //   ..color = (isDark ? const Color(0xFF374151) : const Color(0xFFCBD5E1)).withOpacity(0.7)
      //   ..strokeWidth = 1.0;

      // const double step = 20.0;
      // for (double i = -h; i < w; i += step) {
      //   canvas.drawLine(
      //     Offset(i, 0),
      //     Offset(i + h, h),
      //     stripePaint,
      //   );
      // }

      // Bounding dotted border to visually see boundary in designer
      final borderPaint = Paint()
        ..color = isSelected
            ? const Color(0xFF3B82F6)
            : (isDark ? const Color(0xFF374151) : const Color(0xFF94A3B8)).withOpacity(0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      final RRect borderRect = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(4));
      canvas.drawRRect(borderRect, borderPaint);
    }
  }

  Path _buildDashedPath(Path source, double dashWidth, double dashSpace) {
    final Path dest = Path();
    for (final PathMetric metric in source.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        dest.addPath(
          metric.extractPath(distance, distance + dashWidth),
          Offset.zero,
        );
        distance += dashWidth + dashSpace;
      }
    }
    return dest;
  }

  @override
  bool shouldRepaint(covariant ArchitecturalEntityPainter oldDelegate) {
    return oldDelegate.type != type || oldDelegate.isSelected != isSelected || oldDelegate.isDark != isDark;
  }
}
