import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../../../menu/data/models/category_model.dart';
import '../../../menu/data/models/department_model.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/data/models/menu_group_model.dart';
import '../../../menu/domain/menu_ordering.dart';
import '../bloc/menu_admin_bloc.dart';

/// Staff-only screen (under `/staff/menu`) to curate which items appear on the
/// customer-facing web ordering menu. Edits are staged locally for a smooth UI
/// and committed in one batch via the Save button.
///
/// Responsive: a centered, width-capped column on wide/desktop web, full-width
/// on phones — matching the app's established `ConstrainedBox(maxWidth: …)`
/// pattern.
class MenuAdminPage extends StatefulWidget {
  const MenuAdminPage({super.key});

  @override
  State<MenuAdminPage> createState() => _MenuAdminPageState();
}

class _MenuAdminPageState extends State<MenuAdminPage> {
  static const _bg = Color(0xff121212);
  static const _accent = Color(0xfff25125);

  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Shared "you have unsaved changes" prompt. Returns true if the user chose to
  /// discard (proceed), false to keep editing.
  Future<bool> _confirmDiscardPrompt(BuildContext context) => _promptDiscardChanges(context);

  /// Discard action in the app bar: clears staged edits but stays on the page.
  Future<void> _confirmDiscard(BuildContext context) async {
    if (await _confirmDiscardPrompt(context) && context.mounted) {
      context.read<MenuAdminBloc>().add(const DiscardChanges());
    }
  }

  /// Back navigation: prompt if there are unsaved changes, then leave.
  Future<void> _handleBack(BuildContext context, bool isDirty) async {
    if (isDirty && !await _confirmDiscardPrompt(context)) return;
    if (!context.mounted) return;
    context.canPop() ? context.pop() : context.go('/staff');
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<MenuAdminBloc, MenuAdminState>(
      // Rebuild the page shell only on structural changes — NOT on every staged
      // toggle. A single toggle changes only `pending`; the checkboxes, category
      // headers, and FAB self-subscribe (context.select / BlocSelector) so they
      // update in isolation without rebuilding the whole list.
      buildWhen: (prev, curr) {
        if (curr.runtimeType != prev.runtimeType) return true;
        if (curr is MenuAdminLoaded && prev is MenuAdminLoaded) {
          return !identical(curr.items, prev.items) ||
              curr.query != prev.query ||
              curr.isSaving != prev.isSaving ||
              curr.isDirty != prev.isDirty;
        }
        return true;
      },
      listenWhen: (prev, curr) => curr is MenuAdminLoaded && curr.errorMessage != null,
      listener: (context, state) {
        if (state is MenuAdminLoaded && state.errorMessage != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                backgroundColor: Colors.redAccent,
                content: Text(state.errorMessage!),
              ),
            );
        }
      },
      builder: (context, state) {
        final loaded = state is MenuAdminLoaded ? state : null;
        final isDirty = loaded?.isDirty ?? false;

        return PopScope(
          canPop: !isDirty,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (await _confirmDiscardPrompt(context) && context.mounted) {
              context.canPop() ? context.pop() : context.go('/staff');
            }
          },
          child: Scaffold(
            backgroundColor: _bg,
            appBar: AppBar(
              backgroundColor: _bg,
              foregroundColor: Colors.white,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _handleBack(context, isDirty),
              ),
              title: const Text('Menu Visibility', style: TextStyle(fontWeight: FontWeight.bold)),
              actions: [
                if (isDirty && !(loaded?.isSaving ?? false))
                  IconButton(
                    tooltip: 'Discard changes',
                    icon: const Icon(Icons.undo),
                    onPressed: () => _confirmDiscard(context),
                  ),
              ],
            ),
            floatingActionButton: const _SaveFab(),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: _buildBody(context, state),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, MenuAdminState state) {
    if (state is MenuAdminLoading || state is MenuAdminInitial) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(_accent),
        ),
      );
    }
    if (state is MenuAdminError) {
      return _ErrorView(
        message: state.message,
        onRetry: () => context.read<MenuAdminBloc>().add(const LoadCuration()),
      );
    }
    state as MenuAdminLoaded;
    return _LoadedView(state: state, searchController: _searchController);
  }
}

/// Save button that subscribes only to the staged-change count + saving flag, so
/// it updates on each toggle without rebuilding the item list.
class _SaveFab extends StatelessWidget {
  const _SaveFab();

  @override
  Widget build(BuildContext context) {
    final info = context.select<MenuAdminBloc, ({int count, bool saving})>((bloc) {
      final s = bloc.state;
      return s is MenuAdminLoaded
          ? (count: s.dirtyCount, saving: s.isSaving)
          : (count: 0, saving: false);
    });
    if (info.count == 0) return const SizedBox.shrink();

    final isSaving = info.saving;
    final count = info.count;
    return FloatingActionButton.extended(
      backgroundColor: const Color(0xfff25125),
      foregroundColor: Colors.white,
      onPressed: isSaving ? null : () => context.read<MenuAdminBloc>().add(const SaveChanges()),
      icon: isSaving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : const Icon(Icons.save),
      label: Text(isSaving ? 'Saving…' : 'Save ($count)'),
    );
  }
}

/// The loaded curation list.
///
/// Everything — department headers, category headers, and item rows — is
/// flattened into ONE `ListView.builder` so the whole thing is virtualized:
/// only rows currently on screen are built, and item thumbnails only start
/// loading when their row scrolls into view. Sections are expanded by default;
/// collapsing simply omits a section's rows from the flat list.
class _LoadedView extends StatefulWidget {
  final MenuAdminLoaded state;
  final TextEditingController searchController;

  const _LoadedView({required this.state, required this.searchController});

  @override
  State<_LoadedView> createState() => _LoadedViewState();
}

class _LoadedViewState extends State<_LoadedView> {
  static const _accent = Color(0xfff25125);

  /// Collapsed section keys (`dept_<id>` / `cat_<id>`). Empty = all expanded.
  final Set<String> _collapsed = {};

  void _toggleCollapsed(String key) {
    setState(() {
      if (!_collapsed.remove(key)) _collapsed.add(key);
    });
  }

  static String _deptKey(_DeptGroup g) =>
      'dept_${g.department?.deptId ?? g.department?.id ?? -1}';

  static String _catKey(_CatGroup g) => 'cat_${g.categoryId}';

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final searching = state.query.isNotEmpty;
    final rows = _flatten(_buildGroups(state), searching);

    return Column(
      children: [
        const _GroupBar(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: TextField(
            controller: widget.searchController,
            style: const TextStyle(color: Colors.white),
            onChanged: (v) => context.read<MenuAdminBloc>().add(SearchChanged(v.trim())),
            decoration: InputDecoration(
              hintText: 'Search items…',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
              prefixIcon: const Icon(Icons.search, color: Colors.white54),
              suffixIcon: state.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white54),
                      onPressed: () {
                        widget.searchController.clear();
                        context.read<MenuAdminBloc>().add(const SearchChanged(''));
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
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text('No items match your search.',
                      style: TextStyle(color: Colors.white54)),
                )
              : ListView.builder(
                  // Extra bottom padding so the FAB never covers the last row.
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: rows.length,
                  itemBuilder: (context, i) => rows[i].build(context, searching, this),
                ),
        ),
      ],
    );
  }

  /// Flattens the Department → Category → item tree into a single row list,
  /// skipping the children of any collapsed section (search forces expansion).
  List<_RowSpec> _flatten(List<_DeptGroup> groups, bool searching) {
    final rows = <_RowSpec>[];
    for (final dept in groups) {
      final deptKey = _deptKey(dept);
      rows.add(_DeptRowSpec(dept));
      if (!searching && _collapsed.contains(deptKey)) continue;
      for (final cat in dept.categories) {
        final catKey = _catKey(cat);
        rows.add(_CatRowSpec(cat));
        if (!searching && _collapsed.contains(catKey)) continue;
        for (final item in cat.items) {
          rows.add(_ItemRowSpec(item));
        }
      }
    }
    return rows;
  }

  /// Builds Department → Category → items grouping honoring the current search
  /// filter and the app's category ordering (orderingIndex, nulls last).
  List<_DeptGroup> _buildGroups(MenuAdminLoaded state) {
    final q = state.query.toLowerCase();
    final filtered = q.isEmpty
        ? state.items
        : state.items
            .where((it) =>
                it.name.toLowerCase().contains(q) || it.barcode.toLowerCase().contains(q))
            .toList();

    final catById = {for (final c in state.categories) (c.categoryId ?? c.id): c};
    final deptById = {for (final d in state.departments) (d.deptId ?? d.id): d};

    final byCategory = <int, List<ItemModel>>{};
    for (final it in filtered) {
      byCategory.putIfAbsent(it.categoryId, () => []).add(it);
    }

    final catsByDept = <int, List<CategoryModel>>{};
    for (final catId in byCategory.keys) {
      final cat = catById[catId];
      final deptId = cat?.departmentId ??
          (byCategory[catId]!.isNotEmpty ? byCategory[catId]!.first.departmentId : 0);
      catsByDept.putIfAbsent(deptId, () => []);
      if (cat != null && !catsByDept[deptId]!.contains(cat)) {
        catsByDept[deptId]!.add(cat);
      }
    }

    // Departments ordered by their defined position (orderingIndex, nulls last),
    // matching the customer menu.
    final deptIds = catsByDept.keys.toList()
      ..sort((a, b) =>
          MenuOrdering.compareDepartments(deptById[a], deptById[b]));

    final groups = <_DeptGroup>[];
    for (final deptId in deptIds) {
      final cats = catsByDept[deptId]!..sort(MenuOrdering.compareCategories);
      final catGroups = <_CatGroup>[];
      for (final cat in cats) {
        final catId = cat.categoryId ?? cat.id;
        final items = byCategory[catId] ?? [];
        items.sort(MenuOrdering.compareItems);
        if (items.isEmpty) continue;
        catGroups.add(_CatGroup(category: cat, items: items));
      }
      // Fold items whose category isn't in the catalog into an "Uncategorized"
      // bucket so nothing silently disappears.
      final knownCatIds = cats.map((c) => c.categoryId ?? c.id).toSet();
      final orphanItems = <ItemModel>[];
      byCategory.forEach((catId, items) {
        final belongsHere = (catById[catId]?.departmentId ??
                (items.isNotEmpty ? items.first.departmentId : 0)) ==
            deptId;
        if (belongsHere && !knownCatIds.contains(catId)) {
          orphanItems.addAll(items);
        }
      });
      if (orphanItems.isNotEmpty) {
        orphanItems.sort(MenuOrdering.compareItems);
        catGroups.add(_CatGroup(category: null, items: orphanItems));
      }
      if (catGroups.isEmpty) continue;
      groups.add(_DeptGroup(department: deptById[deptId], categories: catGroups));
    }
    return groups;
  }
}

// ── Flat-list row specs ──────────────────────────────────────────────────────
// Lightweight descriptors the ListView.builder turns into widgets on demand.

abstract class _RowSpec {
  const _RowSpec();
  Widget build(BuildContext context, bool searching, _LoadedViewState view);
}

class _DeptRowSpec extends _RowSpec {
  final _DeptGroup group;
  const _DeptRowSpec(this.group);

  @override
  Widget build(BuildContext context, bool searching, _LoadedViewState view) {
    final key = _LoadedViewState._deptKey(group);
    final collapsed = !searching && view._collapsed.contains(key);
    return _DeptHeader(
      key: ValueKey(key),
      group: group,
      collapsed: collapsed,
      onTap: searching ? null : () => view._toggleCollapsed(key),
    );
  }
}

class _CatRowSpec extends _RowSpec {
  final _CatGroup group;
  const _CatRowSpec(this.group);

  @override
  Widget build(BuildContext context, bool searching, _LoadedViewState view) {
    final key = _LoadedViewState._catKey(group);
    final collapsed = !searching && view._collapsed.contains(key);
    return _CatHeader(
      key: ValueKey(key),
      group: group,
      collapsed: collapsed,
      onTap: searching ? null : () => view._toggleCollapsed(key),
    );
  }
}

class _ItemRowSpec extends _RowSpec {
  final ItemModel item;
  const _ItemRowSpec(this.item);

  @override
  Widget build(BuildContext context, bool searching, _LoadedViewState view) {
    return _ItemTile(key: ValueKey(item.barcode), item: item);
  }
}

class _DeptGroup {
  final DepartmentModel? department;
  final List<_CatGroup> categories;
  const _DeptGroup({required this.department, required this.categories});
}

class _CatGroup {
  final CategoryModel? category;
  final List<ItemModel> items;
  const _CatGroup({required this.category, required this.items});

  /// Grouping key for select-all writes; -1 for the orphan bucket (no select-all).
  int get categoryId => category?.categoryId ?? category?.id ?? -1;
}

// ── Row widgets ──────────────────────────────────────────────────────────────

class _DeptHeader extends StatelessWidget {
  final _DeptGroup group;
  final bool collapsed;
  final VoidCallback? onTap;

  const _DeptHeader({super.key, required this.group, required this.collapsed, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                group.department?.name ?? 'Other',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            if (onTap != null)
              Icon(collapsed ? Icons.expand_more : Icons.expand_less, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

/// Collapsible category header with a select-all control. Subscribes only to its
/// own visible-count + the saving flag, so a toggle inside it rebuilds just this
/// header — not the whole list.
class _CatHeader extends StatelessWidget {
  final _CatGroup group;
  final bool collapsed;
  final VoidCallback? onTap;

  const _CatHeader({super.key, required this.group, required this.collapsed, this.onTap});

  static const _accent = Color(0xfff25125);

  @override
  Widget build(BuildContext context) {
    final total = group.items.length;
    final info = context.select<MenuAdminBloc, ({int visible, bool saving})>((bloc) {
      final s = bloc.state;
      if (s is! MenuAdminLoaded) return (visible: total, saving: false);
      return (visible: group.items.where(s.visibilityOf).length, saving: s.isSaving);
    });
    final visible = info.visible;
    final bool? triState = visible == 0
        ? false
        : visible == total
            ? true
            : null;
    final canSelectAll = group.categoryId >= 0 && !info.saving;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                (group.category?.name ?? 'Uncategorized').toUpperCase(),
                style: TextStyle(
                  color: Colors.amber.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            Text('$visible/$total', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            Checkbox(
              value: triState,
              tristate: true,
              activeColor: _accent,
              checkColor: Colors.white,
              side: const BorderSide(color: Colors.white54),
              onChanged: canSelectAll
                  ? (_) {
                      // If not all visible → show all; else hide all.
                      final makeVisible = triState != true;
                      context
                          .read<MenuAdminBloc>()
                          .add(ToggleGroupVisibility(group.categoryId, makeVisible));
                    }
                  : null,
            ),
            if (onTap != null)
              Icon(collapsed ? Icons.expand_more : Icons.expand_less,
                  color: Colors.white38, size: 20),
          ],
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final ItemModel item;

  const _ItemTile({super.key, required this.item});

  static const _accent = Color(0xfff25125);

  @override
  Widget build(BuildContext context) {
    // Each tile subscribes only to its own staged visibility + the saving flag,
    // so toggling one item rebuilds just that tile.
    final tile = context.select<MenuAdminBloc, ({bool visible, bool enabled})>((bloc) {
      final s = bloc.state;
      if (s is! MenuAdminLoaded) {
        return (visible: item.isAvailableInWebTable, enabled: false);
      }
      return (visible: s.visibilityOf(item), enabled: !s.isSaving);
    });
    final visible = tile.visible;
    final enabled = tile.enabled;

    return CheckboxListTile(
      value: visible,
      activeColor: _accent,
      checkColor: Colors.white,
      side: const BorderSide(color: Colors.white54),
      controlAffinity: ListTileControlAffinity.trailing,
      onChanged: enabled
          ? (v) => context
              .read<MenuAdminBloc>()
              .add(ToggleItemVisibility(item.barcode, v ?? false))
          : null,
      secondary: SizedBox(
        width: 44,
        height: 44,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _Thumbnail(url: item.displayImage),
        ),
      ),
      title: Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: Text(
        '₱${item.price.toStringAsFixed(2)}',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }
}

/// Item thumbnail. Because it only builds when its row scrolls into view (the
/// list is virtualized), the network fetch is inherently lazy. A placeholder
/// shows immediately and the image fades in once its first frame is decoded.
class _Thumbnail extends StatelessWidget {
  final String? url;

  const _Thumbnail({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url == null) return _placeholder();
    return Image.network(
      url!,
      fit: BoxFit.cover,
      // Decode at ~2× the 44px display size instead of full res.
      cacheWidth: 96,
      cacheHeight: 96,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        // Placeholder sits underneath; the decoded image fades in on top.
        return Stack(
          fit: StackFit.expand,
          children: [
            _placeholder(),
            AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              child: child,
            ),
          ],
        );
      },
      errorBuilder: (context, error, stack) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        color: Colors.white.withValues(alpha: 0.06),
        child: const Icon(Icons.fastfood, color: Colors.white24, size: 20),
      );
}

// ── Shared dialogs ───────────────────────────────────────────────────────────

const _bgColor = Color(0xff121212);
const _accentColor = Color(0xfff25125);

/// "Discard unsaved changes?" prompt. Returns true to proceed (discard).
Future<bool> _promptDiscardChanges(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _bgColor,
      title: const Text('Discard changes?', style: TextStyle(color: Colors.white)),
      content: const Text(
        'Your unsaved menu changes will be lost.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep editing'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Discard', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Prompts for a menu-group name. Returns the trimmed name, or null if cancelled
/// or empty. [initial] pre-fills the field (for rename).
Future<String?> _promptGroupName(
  BuildContext context, {
  required String title,
  required String actionLabel,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _bgColor,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        textCapitalization: TextCapitalization.words,
        onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        decoration: InputDecoration(
          hintText: 'e.g. Weekday Dinner',
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
          enabledBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: const UnderlineInputBorder(
            borderSide: BorderSide(color: _accentColor),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, null),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: Text(actionLabel, style: const TextStyle(color: _accentColor)),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// Confirmation dialog for deleting a group. Returns true to proceed.
Future<bool> _promptDeleteGroup(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _bgColor,
      title: const Text('Delete menu group?', style: TextStyle(color: Colors.white)),
      content: Text(
        'Delete "$name"? Its saved item configuration will be removed. This cannot be undone.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Controls above the item list: pick which menu group's config the checkboxes
/// edit, create/rename/delete groups, and set the active group (which drives the
/// customer web menu). Self-subscribes via `context.select` so per-item toggles
/// don't rebuild it.
class _GroupBar extends StatelessWidget {
  const _GroupBar();

  @override
  Widget build(BuildContext context) {
    final info = context.select<MenuAdminBloc,
        ({
          List<MenuGroupModel> groups,
          int? editingId,
          int? activeId,
          bool saving,
          bool dirty,
        })>((bloc) {
      final s = bloc.state;
      if (s is! MenuAdminLoaded) {
        return (groups: const [], editingId: null, activeId: null, saving: false, dirty: false);
      }
      return (
        groups: s.groups,
        editingId: s.editingGroupId,
        activeId: s.activeGroup?.id,
        saving: s.isSaving,
        dirty: s.isDirty,
      );
    });

    final bloc = context.read<MenuAdminBloc>();

    Future<void> switchEditing(int? id) async {
      if (info.saving) return;
      if (id == info.editingId) return;
      if (info.dirty && !await _promptDiscardChanges(context)) return;
      bloc.add(EditGroup(id));
    }

    MenuGroupModel? findGroup(int? id) {
      if (id == null) return null;
      for (final g in info.groups) {
        if (g.id == id) return g;
      }
      return null;
    }

    final editingGroup = findGroup(info.editingId);
    final activeGroup = findGroup(info.activeId);
    final editingIsActive = editingGroup != null && editingGroup.id == info.activeId;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Active menu:',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  activeGroup?.name ?? 'None (per-item flags)',
                  style: TextStyle(
                    color: activeGroup != null ? _accentColor : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Editing:',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int?>(
                      value: info.editingId,
                      isExpanded: true,
                      dropdownColor: _bgColor,
                      iconEnabledColor: Colors.white54,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      onChanged: info.saving ? null : (v) => switchEditing(v),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Default (per-item flags)'),
                        ),
                        for (final g in info.groups)
                          DropdownMenuItem<int?>(
                            value: g.id,
                            child: Text(g.isActive ? '${g.name}  • ACTIVE' : g.name),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'New menu group',
                icon: const Icon(Icons.add, color: Colors.white70),
                onPressed: info.saving
                    ? null
                    : () async {
                        if (info.dirty && !await _promptDiscardChanges(context)) return;
                        if (!context.mounted) return;
                        final name = await _promptGroupName(
                          context,
                          title: 'New menu group',
                          actionLabel: 'Create',
                        );
                        if (name != null) bloc.add(CreateGroup(name));
                      },
              ),
            ],
          ),
          if (editingGroup != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (!editingIsActive)
                  TextButton.icon(
                    onPressed: info.saving
                        ? null
                        : () => bloc.add(SelectActiveGroup(editingGroup.id)),
                    icon: const Icon(Icons.check_circle_outline, size: 18, color: _accentColor),
                    label: const Text('Set active', style: TextStyle(color: _accentColor)),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('This group is active',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Rename group',
                  icon: const Icon(Icons.edit_outlined, color: Colors.white54, size: 20),
                  onPressed: info.saving
                      ? null
                      : () async {
                          final name = await _promptGroupName(
                            context,
                            title: 'Rename group',
                            actionLabel: 'Rename',
                            initial: editingGroup.name,
                          );
                          if (name != null) bloc.add(RenameGroup(editingGroup.id, name));
                        },
                ),
                IconButton(
                  tooltip: 'Delete group',
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                  onPressed: info.saving
                      ? null
                      : () async {
                          if (await _promptDeleteGroup(context, editingGroup.name)) {
                            bloc.add(DeleteGroup(editingGroup.id));
                          }
                        },
                ),
              ],
            ),
          ],
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
              'Could not load the menu.\n$message',
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
