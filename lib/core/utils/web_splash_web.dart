import 'dart:js_interop';

@JS('removeSplash')
external void _jsRemoveSplash();

/// Calls the `window.removeSplash()` hook defined in `web/index.html`,
/// which fades out and removes the HTML loading splash.
void removeWebSplash() {
  _jsRemoveSplash();
}
