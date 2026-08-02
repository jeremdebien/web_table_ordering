import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/auth_bloc.dart';

/// Staff PIN login shown at `/` when there is no session (local mode).
/// A numeric keypad matching the NYX dark/glass aesthetic; submitting fires
/// [AuthLoginRequested] and the root gate swaps to the waiter tool on success.
class PinLoginPage extends StatefulWidget {
  const PinLoginPage({super.key});

  @override
  State<PinLoginPage> createState() => _PinLoginPageState();
}

class _PinLoginPageState extends State<PinLoginPage> {
  static const int _maxLength = 12;
  String _pin = '';

  void _append(String digit) {
    if (_pin.length >= _maxLength) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += digit);
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _submit() {
    if (_pin.isEmpty) return;
    FocusScope.of(context).unfocus();
    context.read<AuthBloc>().add(AuthLoginRequested(_pin));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/nyx.jpg'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          Container(color: Colors.black.withValues(alpha: 0.55)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: BlocConsumer<AuthBloc, AuthState>(
                    listenWhen: (prev, curr) => curr is AuthFailure,
                    listener: (context, state) {
                      // Clear the field after a failed attempt.
                      setState(() => _pin = '');
                    },
                    builder: (context, state) {
                      final isLoading = state is AuthAuthenticating;
                      final error = state is AuthFailure ? state.message : null;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipOval(
                            child: Image.asset(
                              'assets/images/nyx_logo.jpg',
                              width: 96,
                              height: 96,
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Staff Login',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Enter your PIN to continue',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 28),
                          _PinDots(length: _pin.length, hasError: error != null),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 20,
                            child: error != null
                                ? Text(
                                    error,
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _Keypad(
                            enabled: !isLoading,
                            onDigit: _append,
                            onBackspace: _backspace,
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color.fromARGB(255, 235, 209, 16),
                                foregroundColor: Colors.black,
                                disabledBackgroundColor:
                                    const Color(0xfff25125).withValues(alpha: 0.4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: (isLoading || _pin.isEmpty) ? null : _submit,
                              child: isLoading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(Colors.black),
                                      ),
                                    )
                                  : const Text(
                                      'SIGN IN',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
    // Show a filled dot per entered digit (min row of 4 placeholders).
    final count = length < 4 ? 4 : length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final filled = i < length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          width: 14,
          height: 14,
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
                fontSize: 26,
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
            child: const Icon(Icons.backspace_outlined, color: Colors.white, size: 24),
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
      padding: const EdgeInsets.all(8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.10),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(width: 64, height: 64, child: Center(child: child)),
        ),
      ),
    );
  }
}
