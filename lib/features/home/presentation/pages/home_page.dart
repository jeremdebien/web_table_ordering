import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../table/presentation/bloc/table_bloc.dart';

class HomePage extends StatefulWidget {
  final String? tableUuid;
  const HomePage({super.key, this.tableUuid});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    // Reset any previous table bloc states upon loading the landing page
    context.read<TableBloc>().add(const ResetTableState());
  }

  void _showQrScanner(BuildContext context) {
    final tableBloc = context.read<TableBloc>();
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const QrScannerDialog(),
    ).then((result) {
      tableBloc.add(const ResetTableState());
      if (result == 'show_name_input' && context.mounted) {
        _showTableNameInput(context);
      }
    });
  }

  void _showTableNameInput(BuildContext context) {
    final tableBloc = context.read<TableBloc>();
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => const TableNameDialog(),
    ).then((_) {
      tableBloc.add(const ResetTableState());
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: BlocListener<TableBloc, TableState>(
        listener: (context, state) {
          if (state is TableLoaded) {
            // Dismiss active dialogs if any
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            }
            final uuid = state.table.uuid;
            if (uuid != null && uuid.isNotEmpty) {
              context.go('/table/$uuid');
            }
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              // Background Image
              Container(
                decoration: const BoxDecoration(
                  image: DecorationImage(
                    image: AssetImage("assets/images/bg_image.jpg"),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              // Soft dark overlay to bring out the design elements
              Container(
                color: Colors.black.withValues(alpha: 0.4),
              ),
              // Main Scrollable Body
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 500),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // App Logo
                          Hero(
                            tag: 'app-logo',
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    spreadRadius: 2,
                                  )
                                ],
                              ),
                              child: ClipOval(
                                child: Image.asset(
                                  'assets/images/logo.jpg',
                                  fit: BoxFit.contain,
                                  width: 140,
                                  height: 140,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Brand Title Stack (Matches TablePage branding)
                          Stack(
                            children: [
                              Text(
                                "Welcome to Chickey's Inasal",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'Marous',
                                  foreground: Paint()
                                    ..style = PaintingStyle.stroke
                                    ..strokeWidth = 2.5
                                    ..color = Colors.black,
                                ),
                              ),
                              const Text(
                                "Welcome to Chickey's Inasal",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'Marous',
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Stack(
                            children: [
                              Text(
                                "Taste the best Filipino chicken inasal",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  foreground: Paint()
                                    ..style = PaintingStyle.stroke
                                    ..strokeWidth = 2
                                    ..color = Colors.black,
                                ),
                              ),
                              const Text(
                                "Taste the best Filipino chicken inasal",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.amber,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 32),

                          // Glassmorphic Explanation Container
                          ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: Container(
                                padding: const EdgeInsets.all(24),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.25),
                                    width: 1.5,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    const Icon(
                                      Icons.restaurant_menu,
                                      color: Colors.white,
                                      size: 32,
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      "Convenient Self-Ordering",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      "Browse our menu, customize your order, and request the bill directly from your phone. Select an option below to connect to your table.",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.9),
                                        fontSize: 14,
                                        height: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 40),

                          // Action Buttons
                          // 1. Scan QR Code
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xfff25125),
                                foregroundColor: Colors.white,
                                elevation: 4,
                                shadowColor: const Color(0xfff25125).withValues(alpha: 0.4),
                                side: const BorderSide(color: Colors.white, width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () => _showQrScanner(context),
                              icon: const Icon(Icons.qr_code_scanner, size: 24),
                              label: const Text(
                                'SCAN TABLE QR CODE',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'SolemnSojourn',
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // 2. Enter Table Name
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: Colors.black.withValues(alpha: 0.3),
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.8), width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: () => _showTableNameInput(context),
                              icon: const Icon(Icons.table_restaurant, size: 24),
                              label: const Text(
                                'INPUT TABLE NAME',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'SolemnSojourn',
                                  letterSpacing: 1.2,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A premium dialog that handles QR code scanning with camera fallback.
class QrScannerDialog extends StatefulWidget {
  const QrScannerDialog({super.key});

  @override
  State<QrScannerDialog> createState() => _QrScannerDialogState();
}

class _QrScannerDialogState extends State<QrScannerDialog> with SingleTickerProviderStateMixin {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _hasError = false;
  bool _isPermissionDenied = false;
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  String? _extractTableUuid(String text) {
    final trimmed = text.trim();
    // Regex for standard UUID matching
    final uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    if (uuidRegex.hasMatch(trimmed)) {
      return trimmed;
    }

    // Try parsing as a URL
    try {
      final uri = Uri.parse(trimmed);
      final segments = uri.pathSegments;
      final tableIndex = segments.indexOf('table');
      if (tableIndex != -1 && tableIndex + 1 < segments.length) {
        final potentialUuid = segments[tableIndex + 1];
        if (uuidRegex.hasMatch(potentialUuid)) {
          return potentialUuid;
        }
      }
    } catch (_) {
      // Ignored URL parse error
    }
    return null;
  }

  void _onDetect(BarcodeCapture capture) {
    final barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null) {
        final uuid = _extractTableUuid(rawValue);
        if (uuid != null) {
          _scannerController.stop();
          // Load the table metadata, this transitions TableBloc state
          context.read<TableBloc>().add(GetTable(uuid));
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Center(
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 520),
          decoration: BoxDecoration(
            color: const Color(0xff121212),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 24,
                spreadRadius: 4,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.qr_code_scanner, color: Color(0xfff25125), size: 24),
                        SizedBox(width: 10),
                        Text(
                          'Scan Table QR Code',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
              ),

              // Scanner Viewport or Fallback
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _isPermissionDenied || _hasError
                      ? _buildCameraFallback()
                      : Stack(
                          children: [
                            MobileScanner(
                              controller: _scannerController,
                              onDetect: _onDetect,
                              errorBuilder: (context, error) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted && !_hasError) {
                                    setState(() {
                                      _hasError = true;
                                      if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
                                        _isPermissionDenied = true;
                                      }
                                    });
                                  }
                                });
                                return const SizedBox();
                              },
                            ),
                            // Scanning overlay / grid box
                            _buildScannerOverlay(),
                          ],
                        ),
                ),
              ),

              // Footer explanation
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      _isPermissionDenied || _hasError
                          ? 'Please enter the table name manually instead.'
                          : 'Point your camera at the QR code on your table.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Tip: Scanning the QR code with your phone\'s native camera app will also work!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScannerOverlay() {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final double lineOffset = _animationController.value;
        return Stack(
          children: [
            // Darkened outer borders
            Container(
              decoration: ShapeDecoration(
                shape: QrScannerOverlayShape(
                  borderColor: const Color(0xfff25125),
                  borderRadius: 16,
                  borderLength: 24,
                  borderWidth: 4,
                  cutOutSize: 220,
                ),
              ),
            ),
            // Pulsing Red Laser Line
            Center(
              child: Container(
                width: 220,
                height: 220,
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: 220 * lineOffset),
                  child: Container(
                    height: 3,
                    width: 200,
                    decoration: BoxDecoration(
                      color: const Color(0xfff25125),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xfff25125).withValues(alpha: 0.8),
                          blurRadius: 8,
                          spreadRadius: 1,
                        )
                      ],
                    ),
                  ),
                ),
              ),
            )
          ],
        );
      },
    );
  }

  Widget _buildCameraFallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.videocam_off,
              color: Colors.redAccent,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera Access Blocked',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Camera permissions were denied or your browser requires HTTPS for camera access.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xfff25125),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                Navigator.pop(context, 'show_name_input');
              },
              child: const Text('Use Table Name Instead'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A premium dialog that handles inputting table names and querying them.
class TableNameDialog extends StatefulWidget {
  const TableNameDialog({super.key});

  @override
  State<TableNameDialog> createState() => _TableNameDialogState();
}

class _TableNameDialogState extends State<TableNameDialog> {
  final TextEditingController _inputController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      final name = _inputController.text.trim();
      context.read<TableBloc>().add(GetTableByName(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Center(
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: const Color(0xff121212),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 24,
                spreadRadius: 4,
              )
            ],
          ),
          padding: const EdgeInsets.all(24),
          child: BlocBuilder<TableBloc, TableState>(
            builder: (context, state) {
              final isLoading = state is TableLoading;

              return Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Title Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.table_restaurant, color: Color(0xfff25125), size: 24),
                            SizedBox(width: 10),
                            Text(
                              'Enter Table Name',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                          onPressed: isLoading ? null : () => Navigator.pop(context),
                        )
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Instructions
                    const Text(
                      'Please enter the table name printed on your table (e.g. "Table 1").',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 20),

                    // Input Field
                    TextFormField(
                      controller: _inputController,
                      enabled: !isLoading,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        hintText: 'e.g. Table 1',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xfff25125), width: 1.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Table name cannot be empty';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    // Error Feedback Box
                    if (state is TableError)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                state.message.contains('Exception:') 
                                    ? state.message.split('Exception:').last.trim() 
                                    : 'Table not found. Check the name and try again.',
                                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),

                    // Action Buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: isLoading ? null : () => Navigator.pop(context),
                          child: Text(
                            'Cancel',
                            style: TextStyle(
                              color: isLoading ? Colors.white30 : Colors.white70,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xfff25125),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(0xfff25125).withValues(alpha: 0.5),
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: isLoading ? null : _submit,
                          child: isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                )
                              : const Text(
                                  'Find Table',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Custom painter for drawing a scanner viewport overlay (the borders).
class QrScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final double borderLength;
  final double borderRadius;
  final double cutOutSize;

  const QrScannerOverlayShape({
    this.borderColor = Colors.red,
    this.borderWidth = 3.0,
    this.borderLength = 20.0,
    this.borderRadius = 0.0,
    this.cutOutSize = 250.0,
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..addRect(
        Rect.fromCenter(
          center: rect.center,
          width: cutOutSize,
          height: cutOutSize,
        ),
      );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRect(rect);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final backgroundPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    final boxRect = Rect.fromCenter(
      center: rect.center,
      width: cutOutSize,
      height: cutOutSize,
    );

    // Draw darkened background around cutOut
    final path = Path()
      ..addRect(rect)
      ..addRRect(RRect.fromRectAndRadius(boxRect, Radius.circular(borderRadius)));
    canvas.drawPath(path, backgroundPaint);

    // Draw borders/corners
    final double halfWidth = borderWidth / 2;
    final double radius = borderRadius;

    // Top-Left Corner
    final topLeftPath = Path()
      ..moveTo(boxRect.left + borderLength, boxRect.top - halfWidth)
      ..lineTo(boxRect.left + radius, boxRect.top - halfWidth)
      ..arcToPoint(
        Offset(boxRect.left - halfWidth, boxRect.top + radius),
        radius: Radius.circular(radius),
        clockwise: false,
      )
      ..lineTo(boxRect.left - halfWidth, boxRect.top + borderLength);
    canvas.drawPath(topLeftPath, borderPaint);

    // Top-Right Corner
    final topRightPath = Path()
      ..moveTo(boxRect.right - borderLength, boxRect.top - halfWidth)
      ..lineTo(boxRect.right - radius, boxRect.top - halfWidth)
      ..arcToPoint(
        Offset(boxRect.right + halfWidth, boxRect.top + radius),
        radius: Radius.circular(radius),
      )
      ..lineTo(boxRect.right + halfWidth, boxRect.top + borderLength);
    canvas.drawPath(topRightPath, borderPaint);

    // Bottom-Left Corner
    final bottomLeftPath = Path()
      ..moveTo(boxRect.left + borderLength, boxRect.bottom + halfWidth)
      ..lineTo(boxRect.left + radius, boxRect.bottom + halfWidth)
      ..arcToPoint(
        Offset(boxRect.left - halfWidth, boxRect.bottom - radius),
        radius: Radius.circular(radius),
      )
      ..lineTo(boxRect.left - halfWidth, boxRect.bottom - borderLength);
    canvas.drawPath(bottomLeftPath, borderPaint);

    // Bottom-Right Corner
    final bottomRightPath = Path()
      ..moveTo(boxRect.right - borderLength, boxRect.bottom + halfWidth)
      ..lineTo(boxRect.right - radius, boxRect.bottom + halfWidth)
      ..arcToPoint(
        Offset(boxRect.right + halfWidth, boxRect.bottom - radius),
        radius: Radius.circular(radius),
        clockwise: false,
      )
      ..lineTo(boxRect.right + halfWidth, boxRect.bottom - borderLength);
    canvas.drawPath(bottomRightPath, borderPaint);
  }

  @override
  ShapeBorder scale(double t) {
    return QrScannerOverlayShape(
      borderColor: borderColor,
      borderWidth: borderWidth * t,
      borderLength: borderLength * t,
      borderRadius: borderRadius * t,
      cutOutSize: cutOutSize * t,
    );
  }
}
