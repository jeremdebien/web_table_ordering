// Removes the HTML loading splash defined in `web/index.html`.
//
// Uses a conditional import so the app still compiles on non-web targets
// (where the JS interop call is a no-op).
export 'web_splash_stub.dart'
    if (dart.library.js_interop) 'web_splash_web.dart';
