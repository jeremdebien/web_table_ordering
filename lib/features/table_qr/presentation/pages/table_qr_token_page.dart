import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../data/table_qr_session.dart';

/// Entry point of a dynamic table QR (`/t/:token`, printed by the POS).
/// Resolves the token on the consolidator, keeps it for order submits, then
/// forwards to the regular `/table/:uuid` flow — or to the expired page.
class TableQrTokenPage extends StatefulWidget {
  final String token;

  const TableQrTokenPage({super.key, required this.token});

  @override
  State<TableQrTokenPage> createState() => _TableQrTokenPageState();
}

class _TableQrTokenPageState extends State<TableQrTokenPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    String target;
    try {
      final res = await GetIt.instance<TableQrSession>().resolve(widget.token);
      target = res.isOk ? '/table/${res.tableUuid}' : '/qr-expired?reason=${res.status}';
    } catch (_) {
      target = '/qr-expired?reason=invalid';
    }
    if (mounted) context.go(target);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(image: AssetImage('assets/images/welcome_ikoka.png'), fit: BoxFit.cover),
            ),
          ),
          Container(color: Colors.black.withValues(alpha: 0.45)),
          const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: 48, height: 48, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                SizedBox(height: 20),
                Text(
                  'Finding your table…',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
