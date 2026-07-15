import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:web_table_ordering/features/menu/presentation/bloc/menu_bloc.dart';
import 'package:web_table_ordering/features/orders/presentation/bloc/cart_bloc.dart';
import 'package:web_table_ordering/features/table/presentation/bloc/table_bloc.dart';
import '../../../../core/di/injection_container.dart';
import '../../data/datasources/menu_data_source.dart';
import '../../data/models/instruction_group_model.dart';
import '../../../../features/orders/presentation/widgets/cart_summary.dart';
import '../widgets/menu_item_card.dart';
import '../widgets/add_item_bottom_sheet.dart';

class MenuPage extends StatefulWidget {
  const MenuPage({super.key});

  @override
  State<MenuPage> createState() => _MenuPageState();
}
// ... (rest of file)
// This replacement is tricky because imports are at top. I should use multi_replace.
// Cancelling this tool call and switching to multi_replace.
// Actually I can do two replaces or just one view_file to be sure of line numbers again.
// I will start with Import change.

class _MenuPageState extends State<MenuPage> {
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
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

  void _loadNickname() {
    context.read<CartBloc>().add(LoadNickname());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadActiveOrder() {
    final tableState = context.read<TableBloc>().state;
    if (tableState is TableLoaded) {
      context.read<CartBloc>().add(LoadActiveOrder(tableState.table.tableId));
    }
  }

  IconData _getCategoryIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('all')) return Icons.grid_view_rounded;
    if (lower.contains('carte')) return Icons.restaurant;
    if (lower.contains('pasta')) return Icons.soup_kitchen;
    if (lower.contains('main')) return Icons.flatware;
    if (lower.contains('drink') || lower.contains('beverage')) {
      return Icons.local_drink;
    }
    return Icons.dining;
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TableBloc, TableState>(
      listener: (context, state) {
        if (state is TableLoaded) {
          context.read<CartBloc>().add(LoadActiveOrder(state.table.tableId));
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFAF7F2),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: BlocBuilder<CartBloc, CartState>(
          builder: (context, state) {
            if (state.items.isEmpty) return const SizedBox.shrink();
            final totalCount = state.items.fold(
              0,
              (sum, item) => sum + item.quantity,
            );
            final totalAmount = state.items.fold(
              0.0,
              (sum, item) => sum + (item.amount * item.quantity),
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: GestureDetector(
                onTap: () => _showOrderSummary(context),
                child: Container(
                  height: 70,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F0F),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 15,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(
                            Icons.shopping_cart_outlined,
                            color: Colors.white,
                            size: 28,
                          ),
                          Positioned(
                            top: -6,
                            right: -6,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Color(0xFFC5A880),
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 16,
                                minHeight: 16,
                              ),
                              child: Text(
                                '$totalCount',
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 16),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'View Order',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '$totalCount items',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            'Total',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            '₱${totalAmount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(
                          color: Color(0xFFC5A880),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.chevron_right,
                          color: Colors.black,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        body: BlocListener<CartBloc, CartState>(
          listenWhen: (previous, current) =>
              previous.nickname != current.nickname ||
              (previous.deviceId != current.deviceId),
          listener: (context, state) {
            if (state.nickname.isEmpty && state.deviceId != null) {
              _showNicknamePrompt(context);
            }
          },
          child: BlocBuilder<CartBloc, CartState>(
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
                          color: Color(0xfff25125),
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
                            backgroundColor: const Color(0xfff25125),
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

              return BlocBuilder<MenuBloc, MenuState>(
                builder: (context, state) {
                  if (state is MenuLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (state is MenuError) {
                    return Center(child: Text(state.message));
                  }
                  if (state is MenuLoaded) {
                    final displayItems = _isSearching && _searchQuery.isNotEmpty
                        ? state.items
                              .where(
                                (item) => item.name.toLowerCase().contains(
                                  _searchQuery.toLowerCase(),
                                ),
                              )
                              .toList()
                        : state.items
                              .where(
                                (item) =>
                                    item.categoryId == state.selectedCategoryId,
                              )
                              .toList();

                    return CustomScrollView(
                      slivers: [
                        // Food Background Header
                        SliverToBoxAdapter(
                          child: Container(
                            height: 340,
                            alignment: Alignment.topRight,
                            decoration: BoxDecoration(
                              image: DecorationImage(
                                image: const AssetImage(
                                  "assets/images/menubg.png",
                                ),
                                fit: BoxFit.cover,
                              ),
                            ),
                            child: SafeArea(
                              bottom: false,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  top: 10.0,
                                  left: 20.0,
                                  right: 20.0,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
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
                        ),
                        // Beige Content Box
                        SliverToBoxAdapter(
                          child: Transform.translate(
                            offset: const Offset(0, -20),
                            child: Container(
                              padding: const EdgeInsets.only(top: 20),
                              decoration: const BoxDecoration(
                                color: Color(0xFFFAF7F2),
                                borderRadius: BorderRadius.only(
                                  topLeft: Radius.circular(30),
                                  topRight: Radius.circular(30),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 20),
                                  // Categories Horizontal List
                                  SizedBox(
                                    height: 85,
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: state.categories.length,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      itemBuilder: (context, index) {
                                        final category =
                                            state.categories[index];
                                        final isSelected =
                                            category.categoryId ==
                                            state.selectedCategoryId;
                                        return GestureDetector(
                                          onTap: () {
                                            context.read<MenuBloc>().add(
                                              SelectCategory(
                                                category.categoryId ?? 0,
                                              ),
                                            );
                                          },
                                          child: Container(
                                            width: 90,
                                            margin: const EdgeInsets.only(
                                              right: 12,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isSelected
                                                  ? const Color(0xFF1A1A1A)
                                                  : Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: isSelected
                                                  ? Border.all(
                                                      color: const Color(
                                                        0xFFC5A880,
                                                      ),
                                                      width: 1.5,
                                                    )
                                                  : Border.all(
                                                      color:
                                                          Colors.grey.shade200,
                                                      width: 1,
                                                    ),
                                              boxShadow: [
                                                if (!isSelected)
                                                  BoxShadow(
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.03,
                                                        ),
                                                    blurRadius: 8,
                                                    offset: const Offset(0, 2),
                                                  ),
                                              ],
                                            ),
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  _getCategoryIcon(
                                                    category.name,
                                                  ),
                                                  color: isSelected
                                                      ? const Color(0xFFC5A880)
                                                      : Colors.grey.shade700,
                                                  size: 24,
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  category.name,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: isSelected
                                                        ? FontWeight.bold
                                                        : FontWeight.normal,
                                                    color: isSelected
                                                        ? Colors.white
                                                        : Colors.grey.shade800,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  // Category title header
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 16,
                                    ),
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      child: _isSearching
                                          ? Row(
                                              key: const ValueKey(
                                                'search_field',
                                              ),
                                              children: [
                                                Expanded(
                                                  child: Container(
                                                    height: 44,
                                                    decoration: BoxDecoration(
                                                      color: Colors.white,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      border: Border.all(
                                                        color: const Color(
                                                          0xFFC5A880,
                                                        ),
                                                        width: 1.5,
                                                      ),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: Colors.black
                                                              .withValues(
                                                                alpha: 0.06,
                                                              ),
                                                          blurRadius: 8,
                                                          offset: const Offset(
                                                            0,
                                                            2,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    child: TextField(
                                                      controller:
                                                          _searchController,
                                                      autofocus: true,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        color: Color(
                                                          0xFF1A1A1A,
                                                        ),
                                                      ),
                                                      decoration: InputDecoration(
                                                        hintText:
                                                            'Search menu…',
                                                        hintStyle: TextStyle(
                                                          color: Colors
                                                              .grey
                                                              .shade400,
                                                          fontSize: 15,
                                                        ),
                                                        prefixIcon: const Icon(
                                                          Icons.search,
                                                          color: Color(
                                                            0xFFC5A880,
                                                          ),
                                                          size: 20,
                                                        ),
                                                        border:
                                                            InputBorder.none,
                                                        contentPadding:
                                                            const EdgeInsets.symmetric(
                                                              vertical: 12,
                                                            ),
                                                      ),
                                                      onChanged: (value) {
                                                        setState(() {
                                                          _searchQuery = value;
                                                        });
                                                      },
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                GestureDetector(
                                                  onTap: () {
                                                    setState(() {
                                                      _isSearching = false;
                                                      _searchQuery = '';
                                                      _searchController.clear();
                                                    });
                                                  },
                                                  child: Container(
                                                    width: 44,
                                                    height: 44,
                                                    decoration:
                                                        const BoxDecoration(
                                                          color: Color(
                                                            0xFF1A1A1A,
                                                          ),
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                    child: const Icon(
                                                      Icons.close,
                                                      color: Colors.white,
                                                      size: 20,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Row(
                                              key: const ValueKey(
                                                'category_title',
                                              ),
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  state.categories
                                                      .firstWhere(
                                                        (c) =>
                                                            c.categoryId ==
                                                            state
                                                                .selectedCategoryId,
                                                        orElse: () => state
                                                            .categories
                                                            .first,
                                                      )
                                                      .name,
                                                  style: const TextStyle(
                                                    fontSize: 20,
                                                    fontWeight: FontWeight.bold,
                                                    fontFamily: 'serif',
                                                    color: Color(0xFF1A1A1A),
                                                  ),
                                                ),
                                                GestureDetector(
                                                  onTap: () {
                                                    setState(() {
                                                      _isSearching = true;
                                                      _searchQuery = '';
                                                      _searchController.clear();
                                                    });
                                                  },
                                                  child: Container(
                                                    width: 38,
                                                    height: 38,
                                                    decoration:
                                                        const BoxDecoration(
                                                          color: Color(
                                                            0xFF1A1A1A,
                                                          ),
                                                          shape:
                                                              BoxShape.circle,
                                                        ),
                                                    child: const Icon(
                                                      Icons.search,
                                                      color: Colors.white,
                                                      size: 20,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                                  // GridView for items
                                  displayItems.isEmpty
                                      ? const Center(
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                              vertical: 40.0,
                                            ),
                                            child: Text(
                                              'No items found',
                                              style: TextStyle(
                                                fontSize: 16,
                                                color: Colors.grey,
                                              ),
                                            ),
                                          ),
                                        )
                                      : GridView.builder(
                                          shrinkWrap: true,
                                          physics:
                                              const NeverScrollableScrollPhysics(),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          gridDelegate:
                                              const SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: 2,
                                                childAspectRatio: 0.65,
                                                crossAxisSpacing: 12,
                                                mainAxisSpacing: 12,
                                              ),
                                          itemCount: displayItems.length,
                                          itemBuilder: (context, index) {
                                            final item = displayItems[index];
                                            String? badgeText;
                                            Color? badgeColor;
                                            Color badgeTextColor = Colors.white;
                                            if (index % 4 == 0) {
                                              badgeText = '★ BESTSELLER';
                                              badgeColor = const Color(
                                                0xFFC5A880,
                                              );
                                              badgeTextColor = Colors.black;
                                            } else if (index % 4 == 1) {
                                              badgeText = '🔥 POPULAR';
                                              badgeColor = const Color(
                                                0xFFE25822,
                                              );
                                            } else if (index % 4 == 2) {
                                              badgeText = 'NEW';
                                              badgeColor = Colors.black;
                                            }

                                            return MenuItemCard(
                                              item: item,
                                              onTap: () =>
                                                  _showAddItemConfirmation(
                                                    context,
                                                    item,
                                                  ),
                                            );
                                          },
                                        ),
                                  const SizedBox(
                                    height: 100,
                                  ), // padding for floating action button
                                ],
                              ),
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
      ),
    );
  }

  void _showOrderSummary(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: Colors.white,
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag indicator
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Color.fromARGB(255, 0, 0, 0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Expanded(child: CartSummary()),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAddItemConfirmation(
    BuildContext context,
    dynamic item,
  ) async {
    List<InstructionGroup> instructionGroups = [];
    try {
      instructionGroups = await sl<MenuDataSource>().getItemInstructions(
        item.barcode,
      );
    } catch (_) {
      instructionGroups = [];
    }
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.5),
      constraints: const BoxConstraints(maxWidth: 500),
      builder: (_) => AddItemBottomSheet(
        item: item,
        instructionGroups: instructionGroups,
      ),
    );
  }

  void _showNicknamePrompt(BuildContext context, {String initialValue = ''}) {
    final controller = TextEditingController(text: initialValue);
    showDialog(
      context: context,
      barrierDismissible:
          initialValue.isNotEmpty, // Only dismissible if they already have one
      builder: (context) {
        return AlertDialog(
          title: Text(
            initialValue.isEmpty
                ? 'Welcome! Enter your nickname'
                : 'Change Nickname',
          ),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'e.g. John D.',
              labelText: 'Nickname',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
            autofocus: true,
          ),
          actions: [
            if (initialValue.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ElevatedButton(
              onPressed: () {
                final nick = controller.text.trim();
                if (nick.isNotEmpty) {
                  context.read<CartBloc>().add(UpdateNickname(nick));
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xfff25125),
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }
}
