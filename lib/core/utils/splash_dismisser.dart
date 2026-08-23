import 'package:flutter/material.dart';
import 'web_splash.dart';

/// Wraps a cold-entry page and lifts the HTML loading splash (see
/// `web/index.html`) once the page is actually ready to paint.
///
/// If [precache] is provided (typically the page's full-screen background
/// image) the splash is kept up until that image has decoded, so there is no
/// blank/dark gap between the splash fading out and the first real frame. If
/// [precache] is null the splash is lifted on the first post-frame callback.
///
/// `removeWebSplash()` is idempotent, so wrapping several routes is safe: only
/// the first cold-load route that mounts actually dismisses the splash; later
/// navigations are no-ops.
class SplashDismisser extends StatefulWidget {
  final Widget child;
  final ImageProvider? precache;

  const SplashDismisser({super.key, required this.child, this.precache});

  @override
  State<SplashDismisser> createState() => _SplashDismisserState();
}

class _SplashDismisserState extends State<SplashDismisser> {
  bool _handled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_handled) return;
    _handled = true;

    final image = widget.precache;
    if (image != null) {
      // Keep the splash up until the background image is decoded and cached,
      // so the page paints it on the very frame the splash fades out.
      precacheImage(image, context).whenComplete(removeWebSplash);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => removeWebSplash());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
