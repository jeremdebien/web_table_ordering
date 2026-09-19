import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/staff_routes.dart';
import '../../../orders/data/datasources/orders_data_source.dart';
import '../../../table/data/models/ground_model.dart';
import '../../../table/data/models/layout_item_model.dart';
import '../../../table/data/models/table_model.dart';
import '../../../table/presentation/bloc/table_bloc.dart';
import '../../../table/presentation/widgets/blueprint/architectural_entity_painter.dart';
import '../../../table/presentation/widgets/blueprint/layout_element_widget.dart';
import '../../../table/presentation/widgets/blueprint/table_shape_widget.dart';
import '../bloc/clear_orders_bloc.dart';

/// Staff-only screen (`/staff/tables`) to clear (settle) a table's open order.
/// Modeled on the POS table picker: a ground (floor) pill selector, per-table
/// status colors, search, an open-only toggle, and a spatial blueprint view for
/// custom-layout grounds with a 90° rotate button for phones.
///
/// Clearing sets `payment_status = 2` via the existing
/// `OrdersDataSource.updatePaymentStatus`. Local-mode only.
///
/// With [orderMode] (`/staff/order`) the same floor plan is a table picker for
/// waiter ordering: every table is tappable and a tap opens its menu.
class ClearOrdersPage extends StatefulWidget {
  final bool orderMode;

  const ClearOrdersPage({super.key, this.orderMode = false});

  @override
  State<ClearOrdersPage> createState() => _ClearOrdersPageState();
}

class _ClearOrdersPageState extends State<ClearOrdersPage> {
  static const _bg = Color(0xff121212);
  static const _accent = Color(0xfff25125);

  final _searchController = TextEditingController();

  /// Pure view state: 0 = normal, 1 = rotated 90° so a wide floor plan fits a
  /// vertical phone. Not persisted.
  int _quarterTurns = 0;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Grounds that have at least one table passing the current filter.
  List<GroundModel> _visibleGrounds(ClearOrdersLoaded s) {
    final withMatch = <int>{};
    for (final t in s.tables) {
      if (s.tableMatchesFilter(t)) withMatch.add(t.groundId);
    }
    return s.grounds.where((g) => withMatch.contains(g.id)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ClearOrdersBloc, ClearOrdersState>(
      listenWhen: (prev, curr) =>
          curr is ClearOrdersLoaded && curr.clearError != null,
      listener: (context, state) {
        if (state is ClearOrdersLoaded && state.clearError != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                backgroundColor: Colors.redAccent,
                content: Text('Could not clear the order: ${state.clearError}'),
              ),
            );
        }
      },
      builder: (context, state) {
        final loaded = state is ClearOrdersLoaded ? state : null;
        final showRotate = loaded?.selectedGround?.isCustomLayout ?? false;

        return Scaffold(
          backgroundColor: _bg,
          appBar: AppBar(
            backgroundColor: _bg,
            foregroundColor: Colors.white,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.canPop() ? context.pop() : context.go(staffHomePath),
            ),
            title: Text(
              widget.orderMode ? 'Select Table' : 'Clear Orders',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            actions: [
              if (showRotate)
                IconButton(
                  tooltip: 'Rotate floor plan',
                  icon: const Icon(Icons.screen_rotation),
                  onPressed: () => setState(() => _quarterTurns = (_quarterTurns + 1) % 2),
                ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () => context.read<ClearOrdersBloc>().add(const LoadTables()),
              ),
            ],
          ),
          body: SafeArea(child: _buildBody(context, state)),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ClearOrdersState state) {
    if (state is ClearOrdersLoading || state is ClearOrdersInitial) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(_accent),
        ),
      );
    }
    if (state is ClearOrdersError) {
      return _ErrorView(
        message: state.message,
        onRetry: () => context.read<ClearOrdersBloc>().add(const LoadTables()),
      );
    }
    state as ClearOrdersLoaded;

    final visibleGrounds = _visibleGrounds(state);

    // Resolve the ground to render. If the selected ground was filtered out
    // (e.g. by a search), fall back to the first visible one and sync the bloc.
    GroundModel? effective = state.selectedGround;
    final selectedStillVisible =
        effective != null && visibleGrounds.any((g) => g.id == effective!.id);
    if (!selectedStillVisible) {
      effective = visibleGrounds.isNotEmpty ? visibleGrounds.first : null;
      if (effective != null && effective.id != state.selectedGroundId) {
        final target = effective;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.read<ClearOrdersBloc>().add(SelectGround(target.id));
        });
      }
    }

    final groundTables = effective == null
        ? const <TableModel>[]
        : (state.tables
            .where((t) => t.groundId == effective!.id && state.tableMatchesFilter(t))
            .toList());

    return Column(
      children: [
        _buildHeader(context, state),
        _buildGroundPills(context, state, visibleGrounds, effective),
        Expanded(
          child: effective == null
              ? const _EmptyView(message: 'No tables to show.')
              : (effective.isCustomLayout
                  ? RotatedBox(
                      quarterTurns: _quarterTurns,
                      child: _BlueprintView(
                        ground: effective,
                        tables: groundTables,
                        layoutItems: state.layoutItems
                            .where((i) => i.groundId == effective!.id)
                            .toList(),
                        state: state,
                        orderMode: widget.orderMode,
                        onTap: (t) => _handleTableTap(context, state, t),
                      ),
                    )
                  : _GridView(
                      tables: groundTables,
                      state: state,
                      orderMode: widget.orderMode,
                      onTap: (t) => _handleTableTap(context, state, t),
                    )),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, ClearOrdersLoaded state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: (v) =>
                  context.read<ClearOrdersBloc>().add(SearchChanged(v.trim())),
              decoration: InputDecoration(
                hintText: 'Search tables…',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                suffixIcon: state.query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white54),
                        onPressed: () {
                          _searchController.clear();
                          context.read<ClearOrdersBloc>().add(const SearchChanged(''));
                        },
                      ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _accent, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Open only', style: TextStyle(color: Colors.white54, fontSize: 11)),
              Switch(
                value: state.openOnly,
                activeColor: _accent,
                onChanged: (v) => context.read<ClearOrdersBloc>().add(ToggleOpenOnly(v)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGroundPills(
    BuildContext context,
    ClearOrdersLoaded state,
    List<GroundModel> visibleGrounds,
    GroundModel? effective,
  ) {
    if (visibleGrounds.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: visibleGrounds.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final g = visibleGrounds[i];
          final selected = g.id == effective?.id;
          return ChoiceChip(
            label: Text(g.description),
            selected: selected,
            showCheckmark: false,
            labelStyle: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontWeight: FontWeight.bold,
            ),
            // Solid dark fills: the translucent white used before picked up the
            // light theme's surface and washed out the white label.
            backgroundColor: const Color(0xff2a2a2a),
            selectedColor: _accent,
            side: BorderSide(
              color: selected ? _accent : Colors.white.withValues(alpha: 0.15),
            ),
            onSelected: (_) => context.read<ClearOrdersBloc>().add(SelectGround(g.id)),
          );
        },
      ),
    );
  }

  Future<void> _handleTableTap(
    BuildContext context,
    ClearOrdersLoaded state,
    TableModel table,
  ) async {
    if (widget.orderMode) {
      final uuid = table.uuid;
      if (uuid == null || uuid.isEmpty) return;
      context.read<TableBloc>().add(GetTable(uuid));
      context.go('/table/$uuid/menu');
      return;
    }

    final order = state.openOrders[table.id];
    if (order == null) return; // empty table — nothing to clear

    final bloc = context.read<ClearOrdersBloc>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ClearConfirmDialog(table: table),
    );
    if (confirmed == true) {
      bloc.add(ClearTable(tableId: table.id, salesOrderId: order.salesOrderId));
    }
  }
}

// ── Status coloring ──────────────────────────────────────────────────────────

/// Resolves a table's display color from its open order's payment status.
class _TableColors {
  final Color border;
  final Color fill;
  final Color text;
  final String label;
  const _TableColors(this.border, this.fill, this.text, this.label);

  factory _TableColors.forTable(ClearOrdersLoaded state, TableModel t) {
    final order = state.openOrders[t.id];
    if (order == null) {
      return _TableColors(
        Colors.white.withValues(alpha: 0.25),
        Colors.white.withValues(alpha: 0.04),
        Colors.white54,
        'Available',
      );
    }
    if (order.paymentStatus == 1) {
      return _TableColors(
        Colors.amber.shade600,
        Colors.amber.withValues(alpha: 0.14),
        Colors.amber.shade200,
        'Bill requested',
      );
    }
    return _TableColors(
      Colors.green.shade600,
      Colors.green.withValues(alpha: 0.14),
      Colors.green.shade200,
      'Occupied',
    );
  }
}

// ── Grid layout (non-custom grounds) ─────────────────────────────────────────

class _GridView extends StatelessWidget {
  final List<TableModel> tables;
  final ClearOrdersLoaded state;
  final bool orderMode;
  final ValueChanged<TableModel> onTap;

  const _GridView({
    required this.tables,
    required this.state,
    required this.orderMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (tables.isEmpty) {
      return _EmptyView(
        message: state.openOnly ? 'No open tables here.' : 'No tables match your search.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final cross = (constraints.maxWidth / 170).floor().clamp(3, 8);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            childAspectRatio: 1.25,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: tables.length,
          itemBuilder: (context, i) {
            final t = tables[i];
            return _TableCard(
              table: t,
              colors: _TableColors.forTable(state, t),
              tappable: orderMode || state.isOpen(t.id),
              hint: orderMode ? 'Tap to order' : 'Tap to clear',
              onTap: () => onTap(t),
            );
          },
        );
      },
    );
  }
}

class _TableCard extends StatelessWidget {
  final TableModel table;
  final _TableColors colors;
  final bool tappable;
  final String hint;
  final VoidCallback onTap;

  const _TableCard({
    required this.table,
    required this.colors,
    required this.tappable,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tappable ? onTap : null,
        child: Container(
          decoration: BoxDecoration(
            color: colors.fill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border, width: 1.5),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                table.description,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                colors.label,
                style: TextStyle(color: colors.text, fontSize: 11),
              ),
              if (tappable) ...[
                const SizedBox(height: 4),
                Text(hint,
                    style: const TextStyle(color: Colors.white38, fontSize: 10)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Blueprint layout (custom grounds) ────────────────────────────────────────

/// Spatial floor plan drawn like the POS blueprint (shared [TableShapeWidget],
/// chairs, layout structures), fit-to-viewport and colored by status.
/// Combine/split/lock badges from the POS are intentionally omitted.
class _BlueprintView extends StatefulWidget {
  final GroundModel ground;
  final List<TableModel> tables;

  /// Structures for this ground; never filtered by search / open-only.
  final List<LayoutItemModel> layoutItems;
  final ClearOrdersLoaded state;
  final bool orderMode;
  final ValueChanged<TableModel> onTap;

  const _BlueprintView({
    required this.ground,
    required this.tables,
    required this.layoutItems,
    required this.state,
    required this.orderMode,
    required this.onTap,
  });

  @override
  State<_BlueprintView> createState() => _BlueprintViewState();
}

class _BlueprintViewState extends State<_BlueprintView> {
  final _controller = TransformationController();
  Size? _lastViewport;

  @override
  void didUpdateWidget(covariant _BlueprintView old) {
    super.didUpdateWidget(old);
    if (old.ground.id != widget.ground.id) _lastViewport = null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fit(Size vp) {
    final cw = widget.ground.canvasWidth;
    final ch = widget.ground.canvasHeight;
    double scale = widget.ground.initialZoom;
    double dx = 0, dy = 0;
    if (vp.width > 0 && vp.height > 0 && cw > 0 && ch > 0) {
      final fit = math.min(vp.width / cw, vp.height / ch);
      scale = (math.min(1.0, fit) * widget.ground.initialZoom).clamp(0.3, 2.0);
      dx = (vp.width - cw * scale) / 2;
      dy = (vp.height - ch * scale) / 2;
    }
    _controller.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
  }

  Widget _buildTable(TableModel t) {
    final colors = _TableColors.forTable(widget.state, t);
    final tappable = widget.orderMode || widget.state.isOpen(t.id);
    final ground = widget.ground;
    return Positioned(
      left: t.xLoc,
      top: t.yLoc,
      child: GestureDetector(
        onTap: tappable ? () => widget.onTap(t) : null,
        child: TableShapeWidget(
          shape: t.shape,
          label: t.description,
          capacity: t.capacity,
          rotation: t.rotation,
          tableSize: ground.tableSize,
          gridWidth: t.gridWidth,
          gridHeight: t.gridHeight,
          seatLayout: t.seatLayout,
          isAvailable: !widget.state.isOpen(t.id),
          statusColor: colors.border,
          nameScale: t.nameScale ?? ground.tableNameScale,
          chairWidthScale: t.chairWidthScale ?? ground.chairWidthScale,
          chairHeightScale: t.chairHeightScale ?? ground.chairHeightScale,
        ),
      ),
    );
  }

  /// Non-interactive structure, rendered like the POS
  /// `SalesOrderBlueprintView._buildLayoutItem`.
  Widget _buildLayoutItem(LayoutItemModel item, bool isDark) {
    final w = item.width > 0 ? item.width : 100.0;
    final h = item.height > 0 ? item.height : 100.0;
    final Widget child;
    if (isLayoutElementType(item.type)) {
      child = LayoutElementWidget(item: item, isDark: isDark);
    } else if (item.type == 'cashier') {
      child = Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark ? Colors.grey[700]! : Colors.grey[400]!,
            width: 1.5,
          ),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.point_of_sale_rounded,
              size: widget.ground.tableSize * 0.45,
              color: isDark ? Colors.grey[300] : Colors.grey[700],
            ),
            const SizedBox(height: 2),
            Text(
              item.description,
              style: TextStyle(
                fontSize: widget.ground.tableSize * 0.13,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.grey[300] : Colors.grey[800],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
    } else {
      child = CustomPaint(
        painter: ArchitecturalEntityPainter(type: item.type, isSelected: false, isDark: isDark),
      );
    }
    return Positioned(
      left: item.xLoc,
      top: item.yLoc,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: item.rotation * math.pi / 180,
          child: SizedBox(width: w, height: h, child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tables.isEmpty && widget.layoutItems.isEmpty) {
      return _EmptyView(
        message: widget.state.openOnly
            ? 'No open tables here.'
            : 'No tables match your search.',
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final vp = Size(constraints.maxWidth, constraints.maxHeight);
        if (_lastViewport != vp) {
          _lastViewport = vp;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit(vp);
          });
        }
        return InteractiveViewer(
          constrained: false,
          transformationController: _controller,
          minScale: 0.3,
          maxScale: 2.0,
          boundaryMargin: EdgeInsets.symmetric(
            horizontal: math.max(150, constraints.maxWidth),
            vertical: math.max(150, constraints.maxHeight),
          ),
          child: SizedBox(
            width: widget.ground.canvasWidth,
            height: widget.ground.canvasHeight,
            child: Stack(
              children: [
                // Same order as the POS: areas behind tables, the rest on top.
                ...widget.layoutItems
                    .where((i) => i.type == kLayoutArea)
                    .map((i) => _buildLayoutItem(i, isDark)),
                ...widget.tables.map(_buildTable),
                ...widget.layoutItems
                    .where((i) => i.type != kLayoutArea)
                    .map((i) => _buildLayoutItem(i, isDark)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Confirm dialog ───────────────────────────────────────────────────────────

/// Confirms clearing a table, fetching the running total lazily so the grid
/// stays cheap.
class _ClearConfirmDialog extends StatelessWidget {
  final TableModel table;

  const _ClearConfirmDialog({required this.table});

  static const _bg = Color(0xff121212);
  static const _accent = Color(0xfff25125);

  Future<double> _total() async {
    final ds = GetIt.instance<OrdersDataSource>();
    final order = await ds.getActiveOrder(tableId: table.id);
    if (order == null) return 0;
    return order.items.fold<double>(0, (sum, it) => sum + it.totalPrice);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _bg,
      title: Text('Clear ${table.description}?',
          style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This settles the order and marks the table as paid. This cannot be undone here.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          FutureBuilder<double>(
            future: _total(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Text('Loading total…',
                    style: TextStyle(color: Colors.white38));
              }
              final total = snap.data ?? 0;
              return Text(
                'Running total: ₱${total.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Clear order',
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

// ── Shared small views ───────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  final String message;
  const _EmptyView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.table_restaurant_outlined, color: Colors.white24, size: 48),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 12),
            Text(
              'Could not load tables.\n$message',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xfff25125),
                foregroundColor: Colors.white,
              ),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
