import 'dart:js_interop';

@JS('window.location.reload')
external void _jsReload();

/// Forces the browser to reload the current page — used to pull every open
/// client onto the freshest deployed build when staff triggers a reload signal.
void reloadWebApp() {
  _jsReload();
}
