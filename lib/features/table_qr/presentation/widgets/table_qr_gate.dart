import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../table/data/datasources/table_data_source.dart';
import '../../data/table_qr_session.dart';
import '../pages/qr_expired_page.dart';

/// Guards the `/table/:uuid` routes when the store runs dynamic table QR.
///
/// Static mode (or online mode): renders [child] untouched. Dynamic mode:
/// renders [child] only when this browser holds a live token for the table
/// (from a scanned `/t/<token>`), or a waiter is logged in (adopts the table's
/// token via `staff_table_qr`). Otherwise shows the "scan the QR" page. The
/// consolidator enforces the same rule on writes; this just avoids a guest
/// building a cart that can never be submitted.
class TableQrGate extends StatefulWidget {
  final String tableUuid;
  final Widget child;

  const TableQrGate({super.key, required this.tableUuid, required this.child});

  @override
  State<TableQrGate> createState() => _TableQrGateState();
}

class _TableQrGateState extends State<TableQrGate> {
  late Future<bool> _allowed;

  @override
  void initState() {
    super.initState();
    _allowed = _check();
  }

  @override
  void didUpdateWidget(covariant TableQrGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tableUuid != widget.tableUuid) _allowed = _check();
  }

  Future<bool> _check() async {
    final session = GetIt.instance<TableQrSession>();
    if (!await session.isDynamicMode()) return true;
    if (session.hasLiveTokenFor(widget.tableUuid)) return true;

    if (!mounted) return false;
    final authBloc = context.read<AuthBloc>();
    var auth = authBloc.state;
    if (auth is AuthInitial || auth is AuthChecking) {
      try {
        auth = await authBloc.stream
            .firstWhere((s) => s is! AuthInitial && s is! AuthChecking)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (auth is! AuthAuthenticated) return false;

    try {
      final table = await GetIt.instance<TableDataSource>().getTableByUuid(widget.tableUuid);
      return session.adoptStaffToken(tableId: table.id, tableUuid: widget.tableUuid);
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _allowed,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return snap.data == true ? widget.child : const QrExpiredPage(reason: 'scan');
      },
    );
  }
}
