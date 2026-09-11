import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:web_table_ordering/features/kiosk/presentation/widgets/kiosk_checkout_dialog.dart';
import 'package:web_table_ordering/features/menu/presentation/bloc/menu_bloc.dart';
import 'package:web_table_ordering/features/orders/presentation/bloc/cart_bloc.dart';
import 'package:web_table_ordering/features/table/presentation/bloc/table_bloc.dart';
import '../../../../core/di/injection_container.dart';
import '../../data/datasources/menu_data_source.dart';
import '../../data/models/instruction_group_model.dart';
import '../../data/models/item_model.dart';
import '../../../../features/orders/presentation/widgets/cart_summary.dart';
import '../widgets/menu_item_card.dart';
import '../widgets/add_item_bottom_sheet.dart';

class MenuPage extends StatefulWidget {
  /// Android self-order kiosk: no table context, no nickname prompt. The table
  /// and customer name are asked for at checkout (see KioskCheckoutDialog).
  final bool kiosk;

  /// Kiosk: called after an order is placed, to show the success screen.
  final ValueChanged<KioskOrderResult>? onKioskOrderPlaced;

  const MenuPage({super.key, this.kiosk = false, this.onKioskOrderPlaced});

  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> {
  // When true, a guest can only start ordering once the table already has a
  // sales order open (created by staff). Hardcoded for now.
  static const bool _requireSalesOrder = false;

  String _searchQuery = '';
  int? _selectedSearchCategoryId;
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;

  // Guards against opening more than one "Add Item" sheet from rapid taps.
  bool _isAddItemSheetOpen = false;
  // Per-item cache of special-instruction groups (page lifetime).
  final Map<String, List<InstructionGroup>> _instructionCache = {};

  @override
  void initState() {
    super.initState();
    if (widget.kiosk) return;
    _loadActiveOrder();
    _loadNickname();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<CartBloc>().state;
      if (state.nickname.isEmpty && state.deviceId != null) {
        _showNicknamePrompt(context);
      }
    });
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _searchQuery = value.trim();
        if (_searchQuery.isEmpty) {
          _selectedSearchCategoryId = null;
        }
      });
    });
  }

  void _clearSearch() {
    _debounceTimer?.cancel();
    setState(() {
      _searchQuery = '';
      _selectedSearchCategoryId = null;
      _searchController.clear();
    });
  }

  void _loadNickname() {
    context.read<CartBloc>().add(LoadNickname());
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _loadActiveOrder() {
    final tableState = context.read<TableBloc>().state;
    if (tableState is TableLoaded) {
      context.read<CartBloc>().add(LoadActiveOrder(tableState.table.tableId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TableBloc, TableState>(
      listenWhen: (previous, current) => !widget.kiosk,
      listener: (context, state) {
        if (state is TableLoaded) {
          context.read<CartBloc>().add(LoadActiveOrder(state.table.tableId));
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFAF7F2),
        body: BlocListener<CartBloc, CartState>(
          listenWhen: (previous, current) =>
              !widget.kiosk &&
              (previous.nickname != current.nickname || (previous.deviceId != current.deviceId)),
          listener: (context, state) {
            if (state.nickname.isEmpty && state.deviceId != null) {
              _showNicknamePrompt(context);
            }
          },
          child: Column(
            children: [
              Expanded(
                child: BlocBuilder<CartBloc, CartState>(
                  // Only these fields drive this subtree. Cart item changes are
                  // handled by the separate builder in the bottom "View Order"
                  // bar, so adding items no longer rebuilds the whole menu grid
                  // or re-runs the search filter.
                  buildWhen: (prev, curr) =>
                      prev.paymentStatus != curr.paymentStatus ||
                      prev.salesOrderId != curr.salesOrderId ||
                      prev.status != curr.status ||
                      prev.nickname != curr.nickname,
                  builder: (context, cartState) {
                    if (cartState.paymentStatus == 1) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.receipt_long,
                                size: 80,
                                color: Colors.black,
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                "You can't order since you request for a bill.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.black,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: () {
                                  final tableState = context.read<TableBloc>().state;
                                  if (tableState is TableLoaded) {
                                    context.read<CartBloc>().add(
                                      EnableOrdering(tableState.table.tableId),
                                    );
                                  }
                                },
                                child: const Text('Enable ordering again?'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    // Block ordering until the table has a sales order open.
                    // Only decide once the active order has been loaded, so we
                    // don't flash this over a table that actually has an order.
                    final orderLoaded =
                        cartState.status == CartStatus.success || cartState.status == CartStatus.submitted;
                    if (_requireSalesOrder && orderLoaded && cartState.salesOrderId == null) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(
                                Icons.table_restaurant,
                                size: 80,
                                color: Colors.black,
                              ),
                              SizedBox(height: 20),
                              Text(
                                "Ordering isn't available yet.\nPlease ask our staff to open your table first.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return BlocBuilder<MenuBloc, MenuState>(
                      builder: (context, state) {
                        if (state is MenuLoading) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (state is MenuError) {
                          return Center(child: Text(state.message));
                        }
                        // Nothing visible (e.g. an active menu group with no
                        // items enabled): the layout below assumes at least
                        // one category, so show a message instead.
                        if (state is MenuLoaded && state.categories.isEmpty) {
                          return GestureDetector(
                            // Kiosk: keep staff access reachable without the hero.
                            behavior: HitTestBehavior.opaque,
                            onLongPress: widget.kiosk ? () => context.push('/staff') : null,
                            child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'The menu is not available right now.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 16, color: Colors.grey),
                                  ),
                                  const SizedBox(height: 12),
                                  TextButton(
                                    onPressed: () => context.read<MenuBloc>().add(LoadMenu()),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          );
                        }
                        if (state is MenuLoaded) {
                          final isSearching = _searchQuery.isNotEmpty;
                          final query = _searchQuery.toLowerCase();

                          // Single O(N) pass over items to pre-compute search matches and category counts
                          final List<dynamic> allMatchedItems = [];
                          final Map<int, List<dynamic>> matchedItemsByCat = {};

                          if (isSearching) {
                            for (final item in state.items) {
                              if (item.name.toLowerCase().contains(query)) {
                                allMatchedItems.add(item);
                                (matchedItemsByCat[item.categoryId] ??= [])
                                    .add(item);
                              }
                            }
                          }

                          // Filter categories that have matching items when searching
                          final matchingCategories = isSearching
                              ? state.categories
                                  .where((cat) =>
                                      matchedItemsByCat.containsKey(cat.categoryId))
                                  .toList()
                              : state.categories;

                          // In search mode, if selected category no longer matches, fallback to null (All)
                          final effectiveSearchCatId = (_selectedSearchCategoryId != null &&
                                  matchedItemsByCat.containsKey(_selectedSearchCategoryId))
                              ? _selectedSearchCategoryId
                              : null;

                          final List<dynamic> displayItems;
                          if (isSearching) {
                            if (effectiveSearchCatId == null) {
                              displayItems = allMatchedItems;
                            } else {
                              displayItems =
                                  matchedItemsByCat[effectiveSearchCatId] ?? const [];
                            }
                          } else {
                            displayItems = state.items
                                .where((item) =>
                                    item.categoryId == state.selectedCategoryId)
                                .toList();
                          }

                          // Hero image height derived from the asset's exact
                          // aspect ratio (1513x1039) so the full image is shown
                          // at screen width with no cropping when expanded.
                          final double heroHeight =
                              MediaQuery.of(context).size.width * (1039 / 1513);

                          return CustomScrollView(
                            slivers: [
                              // Collapsing header: hero image scrolls away while
                              // the account icon (toolbar) and the search +
                              // category pills (bottom) stay pinned to the top.
                              SliverAppBar(
                                pinned: true,
                                backgroundColor: const Color(0xFFFAF7F2),
                                surfaceTintColor: Colors.transparent,
                                elevation: 2,
                                automaticallyImplyLeading: false,
                                toolbarHeight: 0,
                                expandedHeight: heroHeight + 134,
                                flexibleSpace: FlexibleSpaceBar(
                                  collapseMode: CollapseMode.parallax,
                                  background: Stack(
                                    children: [
                                      // Kiosk: hidden staff access via a
                                      // long-press on the hero (PIN-gated).
                                      GestureDetector(
                                        onLongPress: widget.kiosk
                                            ? () => context.push('/staff')
                                            : null,
                                        child: const Image(
                                          image: AssetImage(
                                            "assets/images/menubg_v3.jpeg",
                                          ),
                                          width: double.infinity,
                                          fit: BoxFit.fitWidth,
                                          alignment: Alignment.topCenter,
                                        ),
                                      ),
                                      if (!widget.kiosk)
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        child: SafeArea(
                                          bottom: false,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              top: 10.0,
                                              left: 20.0,
                                              right: 20.0,
                                            ),
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.end,
                                              children: [
                                                GestureDetector(
                                                  onTap: () => _showNicknamePrompt(
                                                    context,
                                                    initialValue: cartState.nickname,
                                                  ),
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                        Icons.account_circle,
                                                        color: Colors.white,
                                                        size: 24,
                                                      ),
                                                      if (cartState.nickname.isNotEmpty)
                                                        Text(
                                                          cartState.nickname.toLowerCase(),
                                                          style: const TextStyle(
                                                            color: Colors.white70,
                                                            fontSize: 10,
                                                          ),
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                bottom: PreferredSize(
                                  preferredSize: const Size.fromHeight(134),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFFAF7F2),
                                      borderRadius: BorderRadius.only(
                                        topLeft: Radius.circular(30),
                                        topRight: Radius.circular(30),
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(height: 14),
                                        // Search Bar with debounced input and instant clear
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: Container(
                                            height: 48,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(
                                                24,
                                              ),
                                              border: Border.all(
                                                color: const Color(
                                                  0xFFC5A880,
                                                ),
                                                width: 1.5,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withValues(
                                                    alpha: 0.06,
                                                  ),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 3),
                                                ),
                                              ],
                                            ),
                                            child: TextField(
                                              controller: _searchController,
                                              style: const TextStyle(
                                                fontSize: 14.5,
                                                fontWeight: FontWeight.w500,
                                                color: Color(
                                                  0xFF1A1A1A,
                                                ),
                                              ),
                                              decoration: InputDecoration(
                                                hintText: 'Search menu dishes, drinks…',
                                                hintStyle: TextStyle(
                                                  color: Colors.grey.shade400,
                                                  fontSize: 14,
                                                ),
                                                prefixIcon: const Icon(
                                                  Icons.search_rounded,
                                                  color: Color(
                                                    0xFFC5A880,
                                                  ),
                                                  size: 22,
                                                ),
                                                suffixIcon: _searchController.text.isNotEmpty
                                                    ? GestureDetector(
                                                        onTap: _clearSearch,
                                                        child: const Icon(
                                                          Icons.cancel_rounded,
                                                          color: Colors.black45,
                                                          size: 20,
                                                        ),
                                                      )
                                                    : null,
                                                border: InputBorder.none,
                                                contentPadding: const EdgeInsets.symmetric(
                                                  vertical: 12,
                                                ),
                                              ),
                                              onChanged: _onSearchChanged,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        // Category Pills with smooth AnimatedSize transition
                                        AnimatedSize(
                                          duration: const Duration(
                                            milliseconds: 280,
                                          ),
                                          curve: Curves.easeInOutCubic,
                                          child: matchingCategories.isEmpty && isSearching
                                              ? const SizedBox.shrink()
                                              : SizedBox(
                                                  height: 42,
                                                  child: ListView.builder(
                                                    scrollDirection: Axis.horizontal,
                                                    itemCount: isSearching
                                                        ? matchingCategories.length + 1
                                                        : state.categories.length,
                                                    padding: const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                    ),
                                                    itemBuilder: (context, index) {
                                                      // In search mode, index 0 is "All (N)"
                                                      if (isSearching && index == 0) {
                                                        final isSelected = effectiveSearchCatId == null;
                                                        return GestureDetector(
                                                          onTap: () {
                                                            setState(() {
                                                              _selectedSearchCategoryId = null;
                                                            });
                                                          },
                                                          child: _buildCategoryChip(
                                                            label: 'All (${allMatchedItems.length})',
                                                            isSelected: isSelected,
                                                          ),
                                                        );
                                                      }

                                                      final category = isSearching
                                                          ? matchingCategories[index - 1]
                                                          : state.categories[index];

                                                      final int categoryMatchCount = isSearching
                                                          ? (matchedItemsByCat[category.categoryId]?.length ?? 0)
                                                          : 0;

                                                      final isSelected = isSearching
                                                          ? effectiveSearchCatId == category.categoryId
                                                          : category.categoryId == state.selectedCategoryId;

                                                      final label = isSearching
                                                          ? '${category.name} ($categoryMatchCount)'
                                                          : category.name;

                                                      return GestureDetector(
                                                        onTap: () {
                                                          if (isSearching) {
                                                            setState(() {
                                                              _selectedSearchCategoryId = category.categoryId;
                                                            });
                                                          } else {
                                                            context.read<MenuBloc>().add(
                                                              SelectCategory(
                                                                category.categoryId ?? 0,
                                                              ),
                                                            );
                                                          }
                                                        },
                                                        child: _buildCategoryChip(
                                                          label: label,
                                                          isSelected: isSelected,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                        ),
                                        const SizedBox(height: 14),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Scrolling content: category title + item grid.
                              SliverToBoxAdapter(
                                child: Container(
                                  color: const Color(0xFFFAF7F2),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                        // Category title header with smooth animated text switcher
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                            vertical: 14,
                                          ),
                                          child: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 250,
                                            ),
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              key: ValueKey(
                                                isSearching
                                                    ? 'search_${effectiveSearchCatId ?? "all"}_${displayItems.length}'
                                                    : 'cat_${state.selectedCategoryId}',
                                              ),
                                              child: Text(
                                                isSearching
                                                    ? (allMatchedItems.isEmpty
                                                        ? 'No Results'
                                                        : (effectiveSearchCatId == null
                                                            ? 'All Results (${allMatchedItems.length})'
                                                            : '${matchingCategories.firstWhere((c) => c.categoryId == effectiveSearchCatId, orElse: () => matchingCategories.first).name} (${displayItems.length})'))
                                                    : (state.categories
                                                        .firstWhere(
                                                          (c) => c.categoryId == state.selectedCategoryId,
                                                          orElse: () => state.categories.first,
                                                        )
                                                        .name),
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                  fontFamily: 'PTSerif',
                                                  color: Color(
                                                    0xFF1A1A1A,
                                                  ),
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                        ),
                                        // GridView for items
                                        displayItems.isEmpty
                                            ? Center(
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(
                                                    vertical: 40.0,
                                                  ),
                                                  child: Text(
                                                    isSearching
                                                        ? 'No items found for "$_searchQuery"'
                                                        : 'No items found',
                                                    style: const TextStyle(
                                                      fontSize: 16,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : LayoutBuilder(
                                                builder: (context, constraints) {
                                                  // Derive the exact cell ratio
                                                  // from the available width so the
                                                  // image is a perfect square and
                                                  // the fixed text block below fits
                                                  // with no overflow at any width.
                                                  const double hPadding = 16;
                                                  const double crossSpacing = 12;
                                                  // Slightly > the real text block
                                                  // (~100px) to leave a hair of slack.
                                                  const double textBlock = 104;
                                                  final double itemWidth =
                                                      (constraints.maxWidth -
                                                              hPadding * 2 -
                                                              crossSpacing) /
                                                          2;
                                                  final double ratio = itemWidth /
                                                      (itemWidth + textBlock);
                                                  return GridView.builder(
                                                    shrinkWrap: true,
                                                    physics: const NeverScrollableScrollPhysics(),
                                                    padding: const EdgeInsets.symmetric(
                                                      horizontal: hPadding,
                                                    ),
                                                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                                      crossAxisCount: 2,
                                                      childAspectRatio: ratio,
                                                      crossAxisSpacing: crossSpacing,
                                                      mainAxisSpacing: 12,
                                                    ),
                                                    itemCount: displayItems.length,
                                                    itemBuilder: (context, index) {
                                                      final item = displayItems[index];
                                                      return MenuItemCard(
                                                        item: item,
                                                        onTap: () => _showAddItemConfirmation(
                                                          context,
                                                          item,
                                                        ),
                                                      );
                                                    },
                                                  );
                                                },
                                              ),
                                        const SizedBox(height: 20),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    );
                  },
                ),
              ),
              // Fixed bottom "View Order" bar
              BlocBuilder<CartBloc, CartState>(
                builder: (context, state) {
                  if (state.items.isEmpty) return const SizedBox.shrink();
                  final totalCount = state.items.fold(
                    0,
                    (sum, item) => sum + item.quantity,
                  );
                  final subtotal = state.totalAmount;
                  final totalAmountWithService = subtotal * 1.10;
                  final hasNewDrafts = state.newOrders.isNotEmpty;

                  return GestureDetector(
                    onTap: () => _showOrderSummary(context),
                    child: Container(
                      height: 68,
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141414),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: hasNewDrafts
                              ? const Color(0xFFC5A880).withValues(alpha: 0.5)
                              : Colors.white.withValues(alpha: 0.1),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.shopping_bag_outlined,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                              Positioned(
                                top: -2,
                                right: -2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFC5A880),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF141414), width: 1.5),
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 18,
                                    minHeight: 18,
                                  ),
                                  child: Text(
                                    '$totalCount',
                                    style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 14),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'View Order',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  if (hasNewDrafts) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFC5A880),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'Draft',
                                        style: TextStyle(
                                          color: Colors.black,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$totalCount ${totalCount == 1 ? 'item' : 'items'} in order',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Total (incl. tax)',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 10.5,
                                ),
                              ),
                              Text(
                                '₱${totalAmountWithService.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 10),
                          Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(
                              color: Color(0xFFC5A880),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.arrow_forward_rounded,
                              color: Colors.black,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showOrderSummary(BuildContext context) async {
    final result = await showModalBottomSheet<KioskOrderResult>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      constraints: const BoxConstraints(maxWidth: 540),
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.9,
          child: CartSummary(kiosk: widget.kiosk),
        );
      },
    );
    if (result != null) {
      _clearSearch();
      widget.onKioskOrderPlaced?.call(result);
    }
  }

  /// Loads an item's special-instruction groups, caching per item so re-opening
  /// the same item is instant and skips the extra Supabase round-trips.
  /// Errors resolve to an empty list and are not cached (transient failures can
  /// be retried on the next open).
  Future<List<InstructionGroup>> _loadInstructions(dynamic item) {
    final int? categoryId =
        item is ItemModel ? item.categoryId : (item.categoryId as int?);
    final key = '${item.barcode}_${categoryId ?? ''}';
    final cached = _instructionCache[key];
    if (cached != null) return Future.value(cached);
    return sl<MenuDataSource>()
        .getItemInstructions(item.barcode, categoryId: categoryId)
        .then((groups) {
      _instructionCache[key] = groups;
      return groups;
    }).catchError((_) => <InstructionGroup>[]);
  }

  void _showAddItemConfirmation(
    BuildContext context,
    dynamic item,
  ) {
    // Cheap insurance against stacking duplicate sheets from rapid taps.
    if (_isAddItemSheetOpen) return;
    _isAddItemSheetOpen = true;

    // Open the sheet immediately; instructions load inside it.
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      constraints: const BoxConstraints(maxWidth: 500),
      builder: (_) => AddItemBottomSheet(
        item: item,
        instructionsFuture: _loadInstructions(item),
      ),
    ).whenComplete(() => _isAddItemSheetOpen = false);
  }

  void _showNicknamePrompt(BuildContext context, {String initialValue = ''}) {
    final controller = TextEditingController(text: initialValue);
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      barrierDismissible: initialValue.isNotEmpty,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF121212),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.1),
              width: 1.5,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFFC5A880,
                            ).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.person_pin,
                            color: Color.fromARGB(255, 235, 209, 16),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          initialValue.isEmpty ? 'Identify Yourself' : 'Edit Nickname',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'PTSerif',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Your nickname will be used to label your items in the shared cart.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: controller,
                      textCapitalization: TextCapitalization.words,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: 'e.g. Joshua M.',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                        ),
                        labelText: 'Nickname',
                        labelStyle: const TextStyle(
                          color: Color.fromARGB(255, 235, 209, 16),
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Color(0xFFC5A880),
                            width: 1.5,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Colors.redAccent,
                            width: 1.5,
                          ),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Colors.redAccent,
                            width: 1.5,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a nickname';
                        }
                        if (value.trim().length < 2) {
                          return 'Nickname must be at least 2 characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (initialValue.isNotEmpty)
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () {
                            if (formKey.currentState!.validate()) {
                              final nick = controller.text.trim();
                              context.read<CartBloc>().add(
                                UpdateNickname(nick),
                              );
                              Navigator.pop(context);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Color.fromARGB(255, 235, 209, 16),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            'Save Name',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
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
      },
    );
  }

  Widget _buildCategoryChip({
    required String label,
    required bool isSelected,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF1A1A1A) : const Color(0xFF3A3A3A),
        borderRadius: BorderRadius.circular(22),
        border: isSelected
            ? Border.all(
                color: const Color(0xFFC5A880),
                width: 1.5,
              )
            : Border.all(
                color: Colors.transparent,
                width: 1.5,
              ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: isSelected ? 0.15 : 0.06,
            ),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          color: isSelected ? Colors.white : Colors.white70,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
