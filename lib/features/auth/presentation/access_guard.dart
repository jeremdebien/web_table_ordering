import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../data/datasources/user_data_source.dart';
import '../data/models/auth_user_model.dart';
import 'bloc/auth_bloc.dart';

const _bg = Color(0xff121212);
const _accent = Color(0xfff25125);

/// Gates a staff-surface action behind an RBAC access key, with an elevated-PIN
/// override — mirroring the POS `AccessControlHelper.guardAction` pattern.
///
/// * If the logged-in waiter already has [accessKey] → run [onGranted] directly.
/// * Otherwise prompt for another (elevated) user's PIN. That user's PIN is
///   verified via the same `verify-waiter-pin` path used for login, and
///   [onGranted] runs only if the matched user's access level grants [accessKey].
///
/// The elevation is one-shot: it authorizes this action only and does NOT
/// replace the current session.
Future<void> guardWebAction(
  BuildContext context, {
  required String accessKey,
  String actionName = '',
  required VoidCallback onGranted,
}) async {
  final authState = context.read<AuthBloc>().state;
  if (authState is AuthAuthenticated && authState.user.hasAccess(accessKey)) {
    onGranted();
    return;
  }

  final granted = await showDialog<AuthUserModel>(
    context: context,
    builder: (_) => _ElevatedPinDialog(accessKey: accessKey, actionName: actionName),
  );

  if (granted != null && context.mounted) {
    onGranted();
  }
}

/// PIN prompt that verifies an elevated user and pops that user only when their
/// access level grants the required key. Pops `null` on cancel.
class _ElevatedPinDialog extends StatefulWidget {
  final String accessKey;
  final String actionName;

  const _ElevatedPinDialog({required this.accessKey, required this.actionName});

  @override
  State<_ElevatedPinDialog> createState() => _ElevatedPinDialogState();
}

class _ElevatedPinDialogState extends State<_ElevatedPinDialog> {
  static const int _maxLength = 12;
  String _pin = '';
  bool _verifying = false;
  String? _error;

  void _append(String digit) {
    if (_verifying || _pin.length >= _maxLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += digit;
      _error = null;
    });
  }

  void _backspace() {
    if (_verifying || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_verifying || _pin.isEmpty) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final user = await GetIt.instance<UserDataSource>().verifyPasscode(_pin.trim());
      if (!mounted) return;
      if (user == null) {
        setState(() {
          _verifying = false;
          _pin = '';
          _error = 'Incorrect PIN';
        });
        return;
      }
      if (!user.hasAccess(widget.accessKey)) {
        setState(() {
          _verifying = false;
          _pin = '';
          _error = "This user isn't authorized for this action";
        });
        return;
      }
      Navigator.pop(context, user);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _pin = '';
        _error = 'Could not verify. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.actionName.isEmpty ? 'Manager approval' : widget.actionName;
    return AlertDialog(
      backgroundColor: _bg,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You are not authorized. Enter an authorized user\'s PIN to continue.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 20),
            _PinDots(length: _pin.length, hasError: _error != null),
            const SizedBox(height: 10),
            SizedBox(
              height: 20,
              child: _error != null
                  ? Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            _Keypad(
              enabled: !_verifying,
              onDigit: _append,
              onBackspace: _backspace,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: (_verifying || _pin.isEmpty) ? null : _submit,
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(_accent),
                  ),
                )
              : const Text('Authorize',
                  style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

class _PinDots extends StatelessWidget {
  final int length;
  final bool hasError;

  const _PinDots({required this.length, required this.hasError});

  @override
  Widget build(BuildContext context) {
    final color = hasError ? Colors.redAccent : Colors.white;
    final count = length < 4 ? 4 : length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final filled = i < length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 5),
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : Colors.transparent,
            border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
          ),
        );
      }),
    );
  }
}

class _Keypad extends StatelessWidget {
  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  const _Keypad({
    required this.enabled,
    required this.onDigit,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, Widget? child}) {
      return _KeypadButton(
        enabled: enabled && onTap != null,
        onTap: onTap,
        child: child ??
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
      );
    }

    Widget row(List<Widget> children) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        );

    return Column(
      children: [
        row([for (final d in ['1', '2', '3']) key(d, onTap: () => onDigit(d))]),
        row([for (final d in ['4', '5', '6']) key(d, onTap: () => onDigit(d))]),
        row([for (final d in ['7', '8', '9']) key(d, onTap: () => onDigit(d))]),
        row([
          key('', onTap: null),
          key('0', onTap: () => onDigit('0')),
          key(
            '',
            onTap: onBackspace,
            child: const Icon(Icons.backspace_outlined, color: Colors.white, size: 22),
          ),
        ]),
      ],
    );
  }
}

class _KeypadButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;
  final Widget child;

  const _KeypadButton({
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: Colors.white.withValues(alpha: 0.10),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(width: 52, height: 52, child: Center(child: child)),
        ),
      ),
    );
  }
}
