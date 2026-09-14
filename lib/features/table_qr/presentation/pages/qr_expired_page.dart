import 'package:flutter/material.dart';

import '../../../../core/utils/splash_dismisser.dart';

/// Shown when a dynamic table QR is expired/revoked/unknown, or when a static
/// table link is opened while the store requires dynamic QR.
class QrExpiredPage extends StatelessWidget {
  /// 'expired' | 'invalid' | 'scan'
  final String reason;

  const QrExpiredPage({super.key, this.reason = 'expired'});

  @override
  Widget build(BuildContext context) {
    final (title, message) = switch (reason) {
      'scan' => ('Scan to order', 'Please scan the QR code provided by our staff to order at this table.'),
      'invalid' => ('QR not recognised', 'This QR code is not valid. Please ask our staff for a new one.'),
      _ => ('QR code expired', 'This QR code has expired. Please ask our staff for a new one.'),
    };

    return SplashDismisser(
      child: Scaffold(
        body: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                image: DecorationImage(
                  image: AssetImage('assets/images/welcome_ikoka.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Container(color: Colors.black.withValues(alpha: 0.55)),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.qr_code_2, color: Colors.white, size: 72),
                    const SizedBox(height: 20),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
