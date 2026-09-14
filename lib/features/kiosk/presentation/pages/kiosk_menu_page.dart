import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../menu/presentation/pages/menu_page.dart';
import '../../../orders/presentation/bloc/cart_bloc.dart';
import '../widgets/kiosk_checkout_dialog.dart';

/// Android self-order kiosk home (`main_kiosk.dart` → `/`). Hosts the menu in
/// kiosk mode and returns to a fresh state after each order, or after the
/// device is left idle with items in the cart.
class KioskMenuPage extends StatefulWidget {
  const KioskMenuPage({super.key});

  @override
  State<KioskMenuPage> createState() => _KioskMenuPageState();
}

class _KioskMenuPageState extends State<KioskMenuPage> {
  static const _idleTimeout = Duration(minutes: 3);
  static const _successDuration = Duration(seconds: 4);

  Timer? _idleTimer;
  Timer? _successTimer;
  KioskOrderResult? _placed;
  // Bumped on every reset so the menu rebuilds from scratch (search, scroll).
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _resetCart();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _successTimer?.cancel();
    super.dispose();
  }

  void _resetCart() => context.read<CartBloc>().add(ResetCart());

  void _onActivity() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _onIdle);
  }

  void _onIdle() {
    if (!mounted || _placed != null) return;
    if (context.read<CartBloc>().state.items.isEmpty) return;
    // Close any open sheet/dialog left by the previous customer.
    Navigator.of(context).popUntil((route) => route.isFirst);
    _startFresh();
  }

  void _onOrderPlaced(KioskOrderResult result) {
    _idleTimer?.cancel();
    setState(() => _placed = result);
    _successTimer?.cancel();
    _successTimer = Timer(_successDuration, _startFresh);
  }

  void _startFresh() {
    if (!mounted) return;
    _successTimer?.cancel();
    _resetCart();
    setState(() {
      _placed = null;
      _session++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final placed = _placed;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onActivity(),
      child: Stack(
        children: [
          MenuPage(
            key: ValueKey(_session),
            kiosk: true,
            onKioskOrderPlaced: _onOrderPlaced,
          ),
          if (placed != null)
            Positioned.fill(
              child: _OrderPlacedScreen(result: placed, onDone: _startFresh),
            ),
        ],
      ),
    );
  }
}

class _OrderPlacedScreen extends StatelessWidget {
  final KioskOrderResult result;
  final VoidCallback onDone;

  const _OrderPlacedScreen({required this.result, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF121212),
      child: InkWell(
        onTap: onDone,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFFC5A880), size: 96),
                const SizedBox(height: 24),
                const Text(
                  'Order Sent!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'PTSerif',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Thank you, ${result.customerName}.\n'
                  'Your order is on its way to table ${result.tableName}.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'Tap anywhere to start a new order',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
