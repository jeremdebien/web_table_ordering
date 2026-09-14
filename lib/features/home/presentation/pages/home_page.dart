import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../../../../core/services/reload_signal_service.dart';
import '../../../table/presentation/bloc/table_bloc.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/access_guard.dart';

const _bg = Color(0xff121212);
const _accent = Color(0xfff25125);

/// Staff home (`/staff` on web, `/` in the waiter app). One primary Add Order
/// action plus the staff settings as on-page tiles — no app-bar actions.
class StaffHomePage extends StatefulWidget {
  const StaffHomePage({super.key});

  @override
  State<StaffHomePage> createState() => _StaffHomePageState();
}

class _StaffHomePageState extends State<StaffHomePage> {
  /// True only while this page's table-name dialog is open. TableBloc is
  /// app-wide, so without this the home (still mounted under `/staff/order`)
  /// would also react to the picker's TableLoaded and pop the wrong route.
  bool _awaitingTableName = false;

  @override
  void initState() {
    super.initState();
    // Reset any previous table bloc states upon loading the staff home
    context.read<TableBloc>().add(const ResetTableState());
  }

  /// Add Order: type the table name, or pick it from the floor plan.
  Future<void> _showAddOrder(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Add Order',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _SheetOption(
                icon: Icons.keyboard,
                label: 'Input table name',
                onTap: () => Navigator.pop(sheetContext, 'name'),
              ),
              const SizedBox(height: 10),
              _SheetOption(
                icon: Icons.grid_view_rounded,
                label: 'Select table',
                onTap: () => Navigator.pop(sheetContext, 'select'),
              ),
            ],
          ),
        ),
      ),
    );

    if (!context.mounted) return;
    if (choice == 'name') {
      final tableBloc = context.read<TableBloc>();
      _awaitingTableName = true;
      await showDialog(
        context: context,
        builder: (_) => const TableNameDialog(),
      );
      _awaitingTableName = false;
      tableBloc.add(const ResetTableState());
    } else if (choice == 'select') {
      context.push('/staff/order');
    }
  }

  /// Confirms, then broadcasts a reload signal that forces every connected
  /// client (all customer devices + this one) to reload onto the latest build.
  Future<void> _confirmAndReloadAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _bg,
        title: const Text('Reload all devices?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Every open device — including customer tablets — will reload '
          'immediately onto the latest version. Continue?',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Reload all',
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await GetIt.instance<ReloadSignalService>().trigger();
      messenger?.showSnackBar(
        const SnackBar(content: Text('Reload signal sent to all devices.')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not send reload signal: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: BlocListener<TableBloc, TableState>(
        listenWhen: (prev, curr) => _awaitingTableName,
        listener: (context, state) {
          if (state is TableLoaded) {
            // Dismiss the table name dialog
            _awaitingTableName = false;
            Navigator.pop(context);
            final uuid = state.table.uuid;
            if (uuid != null && uuid.isNotEmpty) {
              context.go('/table/$uuid/menu');
            }
          }
        },
        child: Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(
            backgroundColor: _bg,
            foregroundColor: Colors.white,
            elevation: 0,
            automaticallyImplyLeading: false,
            titleSpacing: 16,
            title: const _StaffHeader(),
            actions: [
              IconButton(
                tooltip: 'Log out',
                icon: const Icon(Icons.logout),
                onPressed: () => context.read<AuthBloc>().add(const AuthLogout()),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Primary action
                      SizedBox(
                        height: 72,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () => _showAddOrder(context),
                          icon: const Icon(Icons.add_circle_outline, size: 28),
                          label: const Text(
                            'ADD ORDER',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      Text(
                        'SETTINGS',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SettingsTile(
                        icon: Icons.restaurant_menu,
                        title: 'Menu curation',
                        subtitle: 'Choose which items show on web ordering',
                        onTap: () => guardWebAction(
                          context,
                          accessKey: 'web_menu_curation',
                          actionName: 'Menu Curation',
                          onGranted: () => context.push('/staff/menu'),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.table_restaurant,
                        title: 'Clear / settle tables',
                        subtitle: 'Settle open orders from the floor plan',
                        onTap: () => guardWebAction(
                          context,
                          accessKey: 'web_clear_table',
                          actionName: 'Clear / Settle Table',
                          onGranted: () => context.push('/staff/tables'),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.refresh,
                        title: 'Reload all devices',
                        subtitle: 'Force every open device onto the latest version',
                        onTap: () => guardWebAction(
                          context,
                          accessKey: 'web_force_reload',
                          actionName: 'Reload all devices',
                          onGranted: () => _confirmAndReloadAll(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// App bar title: the signed-in staff name.
class _StaffHeader extends StatelessWidget {
  const _StaffHeader();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        final name = state is AuthAuthenticated ? state.user.name : '';
        return Row(
          children: [
            const Icon(Icons.badge_outlined, color: Colors.white70, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Signed in as',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                  ),
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Icon(icon, color: _accent),
          title: Text(
            title,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SheetOption({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

/// Dialog that looks a table up by name via [TableBloc] (`GetTableByName`).
class TableNameDialog extends StatefulWidget {
  const TableNameDialog({super.key});

  @override
  State<TableNameDialog> createState() => _TableNameDialogState();
}

class _TableNameDialogState extends State<TableNameDialog> {
  final TextEditingController _inputController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      final name = _inputController.text.trim();
      context.read<TableBloc>().add(GetTableByName(name));
    }
  }

  OutlineInputBorder _border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
      ),
      title: const Text('Enter Table Name', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 360,
        child: BlocBuilder<TableBloc, TableState>(
          builder: (context, state) {
            final isLoading = state is TableLoading;
            return Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _inputController,
                    autofocus: true,
                    enabled: !isLoading,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: 'e.g. Table 1',
                      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      focusedBorder: _border(_accent, 1.5),
                      enabledBorder: _border(Colors.white.withValues(alpha: 0.2)),
                      disabledBorder: _border(Colors.white.withValues(alpha: 0.05)),
                      errorBorder: _border(Colors.redAccent, 1.5),
                      focusedErrorBorder: _border(Colors.redAccent, 1.5),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Table name cannot be empty';
                      }
                      return null;
                    },
                  ),
                  if (state is TableError) ...[
                    const SizedBox(height: 12),
                    Text(
                      state.message.contains('Exception:')
                          ? state.message.split('Exception:').last.trim()
                          : 'Table not found. Check the name and try again.',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: isLoading ? null : () => Navigator.pop(context),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: isLoading ? null : _submit,
                        child: isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text('Find Table', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
