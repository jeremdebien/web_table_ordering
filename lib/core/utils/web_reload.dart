// Reloads the current page on web.
//
// Uses a conditional import so the app still compiles on non-web targets
// (where the JS interop call is a no-op). Mirrors the `web_splash.dart` pattern.
export 'web_reload_stub.dart'
    if (dart.library.js_interop) 'web_reload_web.dart';
