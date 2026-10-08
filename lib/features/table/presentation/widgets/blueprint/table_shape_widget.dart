// MIRROR of kwikpos_lite lib/modules/table_layout/presentation/widgets/table_shape_widget.dart.
// Keep both copies in sync so the web floor plan renders like the POS.

import 'dart:math' as math;
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';

class TableShapeWidget extends StatelessWidget {
  final String shape; // 'square', 'round', 'rectangle', 'l_shape'
  final String label;
  final int capacity;
  final double rotation; // in degrees (0, 45, 90, etc.)
  final double tableSize;
  final int gridWidth;
  final int gridHeight;
  final String seatLayout;
  final bool isSelected;

  /// Web port: explicit status inputs replace the POS `TableStatus` enum.
  /// [statusColor] tints occupied/billed tables; unused while [isAvailable].
  final Color statusColor;
  final bool isAvailable;

  /// Multiplier on the auto table-name font size (ground scale or per-table
  /// override). 1.0 = default sizing.
  final double nameScale;

  /// Multipliers on the default chair width (along the edge) and depth.
  final double chairWidthScale;
  final double chairHeightScale;

  const TableShapeWidget({
    super.key,
    required this.shape,
    required this.label,
    required this.capacity,
    this.rotation = 0.0,
    required this.tableSize,
    this.gridWidth = 1,
    this.gridHeight = 1,
    this.seatLayout = 'all',
    this.isSelected = false,
    this.statusColor = Colors.white,
    this.isAvailable = true,
    this.nameScale = 1.0,
    this.chairWidthScale = 1.0,
    this.chairHeightScale = 1.0,
  });

  /// AutoSizeText needs an integral floor that never exceeds the start size.
  static double _minFontFor(double fontSize) {
    final scaled = math.max(6.0, (7.0 * math.min(1.0, fontSize / 7.0)).roundToDouble());
    return math.max(1.0, math.min(scaled, fontSize.floorToDouble()));
  }

  double get _labelFontSize =>
      ((shape == 'rectangle' || gridWidth != gridHeight) ? tableSize * 0.16 : tableSize * 0.18) * nameScale;

  @override
  Widget build(BuildContext context) {
    // Rotation in radians
    final double angleInRadians = rotation * (math.pi / 180.0);

    // Aspect ratio & dimensions based on shape & grid spans
    double width = tableSize * gridWidth;
    double height = tableSize * gridHeight;

    if (gridWidth == 1 && gridHeight == 1) {
      if (shape == 'rectangle') {
        width = tableSize * 1.6;
        height = tableSize * 0.9;
      }
    }

    // Colors
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Status colors
    final Color availableBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
    final Color availableStroke = isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1);

    
    final Color selectedStroke = const Color(0xFF3B82F6); // Premium royal blue

    final Color fillBg = isAvailable ? availableBg : statusColor.withOpacity(isDark ? 0.25 : 0.15);
    final Color strokeColor =
        isSelected ? selectedStroke : (isAvailable ? availableStroke : statusColor);

    final Color textColor = isSelected
        ? Colors.white
        : (isAvailable ? (isDark ? const Color(0xFFE2E8F0) : Colors.black) : statusColor);

    // Chair size; depth is capped so the table body never collapses. The body
    // is inset by the chair depth so chairs always sit outside it.
    final double chairWidth = tableSize * 0.25 * chairWidthScale;
    final double chairHeight =
        math.min(tableSize * 0.12 * chairHeightScale, math.min(width, height) * 0.35);

    // Renders the architectural chairs around the table
    Widget buildChairs() {
      final List<Widget> chairs = [];

      final chairDecoration = BoxDecoration(
        color: isAvailable ? availableStroke.withOpacity(0.4) : statusColor.withOpacity(0.3),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: isAvailable ? availableStroke : statusColor.withOpacity(0.6),
          width: 1,
        ),
      );

      if (shape == 'round') {
        // Render chairs radially. Screen angles (y grows downward):
        // right = 0, bottom = π/2, left = π, top = -π/2.
        const double right = 0.0, bottom = math.pi / 2, left = math.pi, top = -math.pi / 2;

        // Spreads [n] chairs evenly on an arc centered at [center], never
        // wider than ~160° so a single side doesn't wrap into its neighbours.
        List<double> arc(double center, int n) {
          if (n <= 0) return const [];
          final double step = math.min(0.5, (math.pi * 0.9) / n);
          final double start = center - step * (n - 1) / 2;
          return [for (int i = 0; i < n; i++) start + i * step];
        }

        final int firstHalf = (capacity + 1) ~/ 2;
        final List<double> angles = switch (seatLayout) {
          'top_bottom' => [...arc(top, firstHalf), ...arc(bottom, capacity - firstHalf)],
          'left_right' => [...arc(left, firstHalf), ...arc(right, capacity - firstHalf)],
          'top' => arc(top, capacity),
          'bottom' => arc(bottom, capacity),
          'left' => arc(left, capacity),
          'right' => arc(right, capacity),
          _ => [for (int i = 0; i < capacity; i++) (2 * math.pi / capacity) * i],
        };

        // Chair centers sit on an ellipse inset by half a chair depth, so the
        // chair's outer edge touches the widget bounds instead of crossing them.
        final double radiusX = (width / 2) - (chairHeight / 2);
        final double radiusY = (height / 2) - (chairHeight / 2);

        for (final double chairAngle in angles) {
          final double centerX = (width / 2) + radiusX * math.cos(chairAngle);
          final double centerY = (height / 2) + radiusY * math.sin(chairAngle);
          // Face the ellipse normal (equals chairAngle on a circle) so chairs
          // on oval tables stay flush with the edge.
          final double normal = math.atan2(math.sin(chairAngle) * radiusX, math.cos(chairAngle) * radiusY);

          chairs.add(Positioned(
            left: centerX - chairWidth / 2,
            top: centerY - chairHeight / 2,
            child: Transform.rotate(
              angle: normal + math.pi / 2,
              child: Container(
                width: chairWidth,
                height: chairHeight,
                decoration: chairDecoration,
              ),
            ),
          ));
        }
      } else {
        // Square, Rectangle or L-Shape edge-based placements
        final bool isTopActive = seatLayout == 'all' || seatLayout == 'top_bottom' || seatLayout == 'top';
        final bool isBottomActive = seatLayout == 'all' || seatLayout == 'top_bottom' || seatLayout == 'bottom';
        final bool isLeftActive = seatLayout == 'all' || seatLayout == 'left_right' || seatLayout == 'left';
        final bool isRightActive = seatLayout == 'all' || seatLayout == 'left_right' || seatLayout == 'right';

        final List<String> activeEdges = [];
        if (isTopActive) activeEdges.add('top');
        if (isBottomActive) activeEdges.add('bottom');
        if (isLeftActive) activeEdges.add('left');
        if (isRightActive) activeEdges.add('right');

        if (activeEdges.isNotEmpty) {
          final Map<String, List<int>> chairsOnEdge = {
            'top': [],
            'bottom': [],
            'left': [],
            'right': [],
          };

          for (int i = 0; i < capacity; i++) {
            final String edge = activeEdges[i % activeEdges.length];
            chairsOnEdge[edge]!.add(i);
          }

          // Top Edge
          final int topCount = chairsOnEdge['top']!.length;
          for (int i = 0; i < topCount; i++) {
            final double leftPos = topCount == 1
                ? (width - chairWidth) / 2
                : (width * 0.15) + i * ((width * 0.7 - chairWidth) / (topCount - 1));
            chairs.add(Positioned(
              left: leftPos,
              top: 0,
              child: Container(
                width: chairWidth,
                height: chairHeight,
                decoration: chairDecoration,
              ),
            ));
          }

          // Bottom Edge
          final int bottomCount = chairsOnEdge['bottom']!.length;
          for (int i = 0; i < bottomCount; i++) {
            final double leftPos = bottomCount == 1
                ? (width - chairWidth) / 2
                : (width * 0.15) + i * ((width * 0.7 - chairWidth) / (bottomCount - 1));
            chairs.add(Positioned(
              left: leftPos,
              bottom: 0,
              child: Container(
                width: chairWidth,
                height: chairHeight,
                decoration: chairDecoration,
              ),
            ));
          }

          // Left Edge
          final int leftCount = chairsOnEdge['left']!.length;
          for (int i = 0; i < leftCount; i++) {
            final double topPos = leftCount == 1
                ? (height - chairWidth) / 2
                : (height * 0.15) + i * ((height * 0.7 - chairWidth) / (leftCount - 1));
            chairs.add(Positioned(
              left: 0,
              top: topPos,
              child: RotatedBox(
                quarterTurns: 1,
                child: Container(
                  width: chairWidth,
                  height: chairHeight,
                  decoration: chairDecoration,
                ),
              ),
            ));
          }

          // Right Edge
          final int rightCount = chairsOnEdge['right']!.length;
          for (int i = 0; i < rightCount; i++) {
            final double topPos = rightCount == 1
                ? (height - chairWidth) / 2
                : (height * 0.15) + i * ((height * 0.7 - chairWidth) / (rightCount - 1));
            chairs.add(Positioned(
              right: 0,
              top: topPos,
              child: RotatedBox(
                quarterTurns: 1,
                child: Container(
                  width: chairWidth,
                  height: chairHeight,
                  decoration: chairDecoration,
                ),
              ),
            ));
          }
        }
      }

      return Stack(children: chairs);
    }

    // Inside table main body
    Widget tableBody;
    if (shape == 'l_shape') {
      tableBody = Container(
        margin: EdgeInsets.all(chairHeight),
        child: CustomPaint(
          painter: LShapePainter(
            fillBg: fillBg,
            strokeColor: strokeColor,
            strokeWidth: isSelected ? 2.5 : 1.5,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0, bottom: 16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AutoSizeText(
                    label,
                    textAlign: TextAlign.center,
                    // Shrink the label down to fit, wrapping onto a second
                    // line before finally ellipsizing at the floor size.
                    maxLines: 2,
                    minFontSize: _minFontFor(tableSize * 0.15 * nameScale),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: tableSize * 0.15 * nameScale,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.people_alt_outlined, size: tableSize * 0.11, color: textColor.withOpacity(0.6)),
                      const SizedBox(width: 2),
                      Text(
                        capacity.toString(),
                        style: TextStyle(
                          color: textColor.withOpacity(0.7),
                          fontSize: tableSize * 0.10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } else {
      tableBody = Container(
        margin: EdgeInsets.all(chairHeight), // Give room for chairs
        decoration: BoxDecoration(
          color: isSelected
              ? selectedStroke
              : (isAvailable ? Colors.white : (isDark ? statusColor : statusColor)),
          shape: (shape == 'round' && gridWidth == gridHeight) ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: (shape == 'round' && gridWidth == gridHeight)
              ? null
              : ((shape == 'round' && gridWidth != gridHeight)
                  ? BorderRadius.circular(1000)
                  : BorderRadius.circular((shape == 'rectangle' || gridWidth != gridHeight) ? 6 : 4)),
          border: Border.all(
            color: strokeColor,
            width: isSelected ? 2.5 : 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected ? selectedStroke.withOpacity(0.3) : Colors.black.withOpacity(isDark ? 0.3 : 0.06),
              blurRadius: isSelected ? 8 : 4,
              offset: const Offset(0, 2),
            )
          ],
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                AutoSizeText(
                  label,
                  textAlign: TextAlign.center,
                  // Shrink the label down to fit, wrapping onto a second
                  // line before finally ellipsizing at the floor size.
                  maxLines: 2,
                  minFontSize: _minFontFor(_labelFontSize),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? textColor : (isAvailable ? Colors.black : Colors.white),
                    fontSize: _labelFontSize,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_alt_outlined,
                        size: tableSize * 0.12,
                        color:
                            isSelected ? textColor : (isAvailable ? Colors.black : Colors.white)),
                    const SizedBox(width: 2),
                    Text(
                      capacity.toString(),
                      style: TextStyle(
                        color: isSelected ? textColor : (isAvailable ? Colors.black : Colors.white),
                        fontSize: tableSize * 0.11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Transform.rotate(
      angle: angleInRadians,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: buildChairs()),
            Positioned.fill(child: tableBody),
          ],
        ),
      ),
    );
  }
}

// Custom Painter to draw a premium architect-styled L-Shape table
class LShapePainter extends CustomPainter {
  final Color fillBg;
  final Color strokeColor;
  final double strokeWidth;

  LShapePainter({
    required this.fillBg,
    required this.strokeColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    // Top-left to top-right
    path.moveTo(0, 0);
    path.lineTo(size.width, 0);
    // Down to 50% height
    path.lineTo(size.width, size.height * 0.5);
    // Inward to 50% width
    path.lineTo(size.width * 0.5, size.height * 0.5);
    // Down to 100% height
    path.lineTo(size.width * 0.5, size.height);
    // Left to 0% width (bottom-left)
    path.lineTo(0, size.height);
    path.close();

    // Fill background
    final fillPaint = Paint()
      ..color = fillBg
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Draw stroke/border
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant LShapePainter oldDelegate) {
    return oldDelegate.fillBg != fillBg ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
