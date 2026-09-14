import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/table_bloc.dart';

/// Resolves a legacy QR `table` name into its table UUID and forwards to
/// `/table/:uuid`.
///
/// Reached only via the router-level `redirect` in `app_router.dart`, which
/// catches any entry carrying a `?table=<name>` query param (the shape printed
/// on the old POS QR codes, e.g. `/app/NYX/index.php?...&table=c6`).
///
/// While resolving we deliberately do NOT dismiss the HTML loading splash
/// (`web/index.html`): on a cold QR scan the branded splash stays up over the
/// sub-second lookup and is lifted by `TablePage` once it mounts. The branded
/// scaffold below is the fallback for warm, in-app navigations where the HTML
/// splash is already gone.
class QrResolverPage extends StatefulWidget {
  final String tableName;

  const QrResolverPage({super.key, required this.tableName});

  @override
  State<QrResolverPage> createState() => _QrResolverPageState();
}

class _QrResolverPageState extends State<QrResolverPage> {
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    final name = widget.tableName.trim();
    // Defer navigation/dispatch until after the first frame so `context.go`
    // and bloc access are safe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (name.isEmpty) {
        _fail();
        return;
      }
      context.read<TableBloc>().add(GetTableByName(name));
    });
  }

  void _fail() {
    if (_navigated || !mounted) return;
    _navigated = true;
    context.go('/404');
  }

  void _succeed(String uuid) {
    if (_navigated || !mounted) return;
    _navigated = true;
    context.go('/table/$uuid');
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TableBloc, TableState>(
      listener: (context, state) {
        if (state is TableLoaded) {
          final uuid = state.table.uuid;
          if (uuid != null && uuid.isNotEmpty) {
            _succeed(uuid);
          } else {
            _fail();
          }
        } else if (state is TableError) {
          _fail();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                image: DecorationImage(
                  image: AssetImage('assets/images/welcome_ikoka.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Container(color: Colors.black.withValues(alpha: 0.45)),
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 3,
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                    'Finding your table…',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
