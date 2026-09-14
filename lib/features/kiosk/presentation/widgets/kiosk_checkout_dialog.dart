import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/di/injection_container.dart';
import '../../../orders/data/datasources/orders_data_source.dart';
import '../../../orders/presentation/bloc/cart_bloc.dart';
import '../../../table/data/datasources/table_data_source.dart';

/// What the kiosk checkout placed, for the success screen.
class KioskOrderResult {
  final String tableName;
  final String customerName;
  const KioskOrderResult({required this.tableName, required this.customerName});
}

/// Asks for the table and customer name, then submits the cart to that table
/// (appending to its open order if it has one). Resolves to the result on
/// success, or null if cancelled.
Future<KioskOrderResult?> showKioskCheckoutDialog(BuildContext context) {
  return showDialog<KioskOrderResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BlocProvider.value(
      value: context.read<CartBloc>(),
      child: const _KioskCheckoutDialog(),
    ),
  );
}

class _KioskCheckoutDialog extends StatefulWidget {
  const _KioskCheckoutDialog();

  @override
  State<_KioskCheckoutDialog> createState() => _KioskCheckoutDialogState();
}

class _KioskCheckoutDialogState extends State<_KioskCheckoutDialog> {
  static const _accent = Color.fromARGB(255, 235, 209, 16);

  final _formKey = GlobalKey<FormState>();
  final _tableController = TextEditingController();
  final _nameController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _tableController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    final tableInput = _tableController.text.trim();
    final customerName = _nameController.text.trim();
    setState(() {
      _submitting = true;
      _error = null;
    });

    final bloc = context.read<CartBloc>();
    try {
      // Resolve directly rather than via TableBloc, whose app-wide listeners
      // (e.g. staff HomePage) would react to a TableLoaded.
      final table = await sl<TableDataSource>().getTableByName(tableInput);

      final outcome = bloc.stream.firstWhere(
        (s) => s.status == CartStatus.submitted || s.status == CartStatus.failure,
      );
      bloc.add(SubmitOrder(
        tableId: table.tableId,
        guestCount: 1,
        customerName: customerName,
        reloadAfter: false,
      ));
      final state = await outcome;
      if (!mounted) return;

      if (state.status == CartStatus.submitted) {
        Navigator.of(context).pop(KioskOrderResult(
          tableName: table.description,
          customerName: customerName,
        ));
      } else {
        setState(() {
          _submitting = false;
          _error = state.errorMessage == SplitTableException.friendlyMessage
              ? state.errorMessage
              : 'Failed to place order: ${state.errorMessage}';
        });
      }
    } catch (_) {
      // getTableByName throws when no table matches.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Table "$tableInput" not found. Please check the table name.';
      });
    }
  }

  InputDecoration _decoration(String label, String hint) {
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: _accent),
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: border(Colors.white.withValues(alpha: 0.2)),
      focusedBorder: border(const Color(0xFFC5A880), 1.5),
      errorBorder: border(Colors.redAccent, 1.5),
      focusedErrorBorder: border(Colors.redAccent, 1.5),
    );
  }

  String? _required(String? value, String message) =>
      (value == null || value.trim().isEmpty) ? message : null;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Place Your Order',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'PTSerif',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tell us your table and name so we can bring your order to you.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _tableController,
                  enabled: !_submitting,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: _decoration('Table name', 'e.g. C6'),
                  validator: (v) => _required(v, 'Please enter your table name'),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _nameController,
                  enabled: !_submitting,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: _decoration('Your name', 'e.g. Joshua M.'),
                  validator: (v) => _required(v, 'Please enter your name'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white.withValues(alpha: 0.6),
                      ),
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                            )
                          : const Text(
                              'Send Order',
                              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
