import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/cart_bloc.dart';
import '../../../table/presentation/bloc/table_bloc.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/presentation/bloc/menu_bloc.dart';
import '../../../kiosk/presentation/widgets/kiosk_checkout_dialog.dart';
import 'cart_item_tile.dart';
import '../../data/datasources/orders_data_source.dart';

enum CartFilter {
  all,
  toOrder,
  inKitchen,
  served,
}

class CartSummary extends StatefulWidget {
  /// Kiosk (Android self-order): "Place Order" asks for the table and customer
  /// name, and the sheet pops with the [KioskOrderResult] instead of showing a
  /// snackbar.
  final bool kiosk;

  const CartSummary({super.key, this.kiosk = false});

  @override
  State<CartSummary> createState() => _CartSummaryState();
}

class _CartSummaryState extends State<CartSummary> {
  bool _isBreakdownExpanded = false;
  CartFilter _selectedFilter = CartFilter.all;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CartBloc, CartState>(
      // The kiosk checkout dialog reports its own result.
      listenWhen: (previous, current) => !widget.kiosk,
      listener: (context, state) {
        if (state.status == CartStatus.submitted) {
          debugPrint('Order submitted successfully!');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Order submitted successfully!'),
              backgroundColor: Color(0xFF2E7D32),
              behavior: SnackBarBehavior.floating,
            ),
          );
          // Close bottom sheet after successful submission
          Navigator.of(context).pop();
        } else if (state.status == CartStatus.failure) {
          debugPrint('Failed to submit order: ${state.errorMessage}');
          // A split-table block is an expected, guest-facing condition — show its
          // message verbatim rather than dressing it as a generic failure.
          final isSplitTable =
              state.errorMessage == SplitTableException.friendlyMessage;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isSplitTable
                  ? state.errorMessage!
                  : 'Failed to submit order: ${state.errorMessage}'),
              backgroundColor:
                  isSplitTable ? Colors.orange.shade800 : Colors.red.shade700,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      builder: (context, state) {
        final cartItems = state.items;

        final draftItems = cartItems.where((i) => i.originalQuantity == 0).toList();
        final kitchenItems = cartItems
            .where((i) => i.originalQuantity > 0 && !i.isServed)
            .toList();
        final servedItems = cartItems.where((i) => i.isServed).toList();
        final hasSubmittedItems = cartItems.any((i) => i.originalQuantity > 0);

        final subtotal = state.activeOrderTotalAmount +
            state.pendingOrderTotalAmount +
            state.newOrderTotalAmount;
        final serviceCharge = subtotal * 0.10;
        final total = subtotal + serviceCharge;
        final totalCount = state.activeOrderCount +
            state.pendingOrdersCount +
            state.newOrdersCount;

        final menuState = context.read<MenuBloc>().state;
        List<ItemModel> menuItems = [];
        if (menuState is MenuLoaded) {
          menuItems = menuState.items;
        }

        String? getDisplayImage(String barcode) {
          if (menuItems.isEmpty) return null;
          try {
            final item = menuItems.firstWhere(
              (element) => element.barcode == barcode,
            );
            return item.displayImage;
          } catch (_) {
            return null;
          }
        }

        return Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            color: Color(0xFFFAF7F2),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle Pill
              Center(
                child: Container(
                  width: 42,
                  height: 4.5,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),

              // Header Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your Order',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A),
                          fontFamily: 'PTSerif',
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$totalCount ${totalCount == 1 ? 'item' : 'items'} in total',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  Material(
                    color: Colors.black.withValues(alpha: 0.05),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Color(0xFF1A1A1A),
                        size: 22,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),

              // Filter Chips (Show when table has both draft and submitted items)
              if (hasSubmittedItems && cartItems.isNotEmpty) ...[
                const SizedBox(height: 14),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip(
                        label: 'All (${cartItems.length})',
                        filter: CartFilter.all,
                      ),
                      if (draftItems.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: 'To Order (${draftItems.length})',
                          filter: CartFilter.toOrder,
                        ),
                      ],
                      if (kitchenItems.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: 'In Kitchen (${kitchenItems.length})',
                          filter: CartFilter.inKitchen,
                        ),
                      ],
                      if (servedItems.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: 'Served (${servedItems.length})',
                          filter: CartFilter.served,
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 12),
              const Divider(color: Color(0xFFE8E5DF), height: 1),
              const SizedBox(height: 10),

              // Scrollable Order Items List
              Expanded(
                child: cartItems.isEmpty
                    ? _buildEmptyCartView(context)
                    : _buildFilteredList(
                        draftItems: draftItems,
                        kitchenItems: kitchenItems,
                        servedItems: servedItems,
                        getDisplayImage: getDisplayImage,
                      ),
              ),

              const SizedBox(height: 8),
              const Divider(color: Color(0xFFE8E5DF), height: 1),
              const SizedBox(height: 10),

              // Summary Calculation Accordion
              InkWell(
                onTap: () {
                  setState(() {
                    _isBreakdownExpanded = !_isBreakdownExpanded;
                  });
                },
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4.0),
                  child: Column(
                    children: [
                      AnimatedSize(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                        child: _isBreakdownExpanded
                            ? Column(
                                children: [
                                  _buildSummaryRow(
                                    'Subtotal',
                                    '₱${subtotal.toStringAsFixed(2)}',
                                  ),
                                  const SizedBox(height: 6),
                                  _buildSummaryRow(
                                    'Service Charge (10%)',
                                    '₱${serviceCharge.toStringAsFixed(2)}',
                                  ),
                                  const SizedBox(height: 10),
                                  const Divider(
                                    color: Color(0xFFE8E5DF),
                                    height: 1,
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  color: Color(0xFF1A1A1A),
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'PTSerif',
                                ),
                              ),
                              const SizedBox(width: 4),
                              AnimatedRotation(
                                turns: _isBreakdownExpanded ? 0.5 : 0.0,
                                duration: const Duration(milliseconds: 250),
                                child: const Icon(
                                  Icons.keyboard_arrow_up_rounded,
                                  color: Color(0xFF1A1A1A),
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '₱${total.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Color(0xFF1A1A1A),
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Bottom Action Button
              _buildBottomActionButton(context, state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilterChip({
    required String label,
    required CartFilter filter,
  }) {
    final isSelected = _selectedFilter == filter;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedFilter = filter;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1A1A1A) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF1A1A1A) : const Color(0xFFDED9D2),
            width: 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? Colors.white : const Color(0xFF5A554E),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyCartView(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFC5A880).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.shopping_bag_outlined,
              size: 36,
              color: Color(0xFF8A6D4B),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your cart is empty',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Explore the menu to add delicious dishes to your order.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilteredList({
    required List<dynamic> draftItems,
    required List<dynamic> kitchenItems,
    required List<dynamic> servedItems,
    required String? Function(String) getDisplayImage,
  }) {
    if (_selectedFilter == CartFilter.toOrder) {
      if (draftItems.isEmpty) return _buildFilterEmptyState('No items to order');
      return ListView.builder(
        itemCount: draftItems.length,
        itemBuilder: (context, index) {
          final item = draftItems[index];
          return CartItemTile(
            item: item,
            displayImage: getDisplayImage(item.itemBarcode),
          );
        },
      );
    }

    if (_selectedFilter == CartFilter.inKitchen) {
      if (kitchenItems.isEmpty) return _buildFilterEmptyState('No items cooking right now');
      return ListView.builder(
        itemCount: kitchenItems.length,
        itemBuilder: (context, index) {
          final item = kitchenItems[index];
          return CartItemTile(
            item: item,
            displayImage: getDisplayImage(item.itemBarcode),
          );
        },
      );
    }

    if (_selectedFilter == CartFilter.served) {
      if (servedItems.isEmpty) return _buildFilterEmptyState('No items served yet');
      return ListView.builder(
        itemCount: servedItems.length,
        itemBuilder: (context, index) {
          final item = servedItems[index];
          return CartItemTile(
            item: item,
            displayImage: getDisplayImage(item.itemBarcode),
          );
        },
      );
    }

    // Default "All" view with section grouping if multiple sections exist
    final hasDraft = draftItems.isNotEmpty;
    final hasKitchenOrServed = kitchenItems.isNotEmpty || servedItems.isNotEmpty;

    if (hasDraft && hasKitchenOrServed) {
      final combinedSubmitted = [...kitchenItems, ...servedItems];
      return ListView(
        children: [
          // Section 1: Draft Items
          _buildSectionHeader(
            title: 'Items to Order',
            count: draftItems.length,
            badgeColor: const Color(0xFFFFF9E6),
            badgeTextColor: const Color(0xFFB78103),
          ),
          const SizedBox(height: 6),
          ...draftItems.map((item) => CartItemTile(
                item: item,
                displayImage: getDisplayImage(item.itemBarcode),
              )),
          const SizedBox(height: 16),

          // Section 2: Current Table Orders
          _buildSectionHeader(
            title: 'Current Table Orders',
            count: combinedSubmitted.length,
            badgeColor: const Color(0xFFE8F5E9),
            badgeTextColor: const Color(0xFF2E7D32),
          ),
          const SizedBox(height: 6),
          ...combinedSubmitted.map((item) => CartItemTile(
                item: item,
                displayImage: getDisplayImage(item.itemBarcode),
              )),
        ],
      );
    }

    // Flat list if only one category exists
    final allItems = [...draftItems, ...kitchenItems, ...servedItems];
    return ListView.builder(
      itemCount: allItems.length,
      itemBuilder: (context, index) {
        final item = allItems[index];
        return CartItemTile(
          item: item,
          displayImage: getDisplayImage(item.itemBarcode),
        );
      },
    );
  }

  Widget _buildSectionHeader({
    required String title,
    required int count,
    required Color badgeColor,
    required Color badgeTextColor,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF2C2824),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: badgeColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: badgeTextColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterEmptyState(String message) {
    return Center(
      child: Text(
        message,
        style: TextStyle(
          color: Colors.grey.shade600,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildBottomActionButton(BuildContext context, CartState state) {
    final hasNewOrders = state.newOrders.isNotEmpty;

    if (hasNewOrders) {
      return SizedBox(
        width: double.infinity,
        height: 54,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A1A1A),
            foregroundColor: Colors.white,
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.25),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(27),
            ),
          ),
          onPressed: state.status == CartStatus.loading
              ? null
              : () => widget.kiosk
                  ? _kioskCheckout(context)
                  : _confirmAndSubmitOrder(context),
          child: state.status == CartStatus.loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Place Order (${state.newOrdersCount} ${state.newOrdersCount == 1 ? 'item' : 'items'})',
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded, size: 19),
                  ],
                ),
        ),
      );
    }

    // When cart only contains already-submitted orders
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF1A1A1A),
          side: const BorderSide(color: Color(0xFF1A1A1A), width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(27),
          ),
        ),
        onPressed: () => Navigator.of(context).pop(),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, size: 20),
            SizedBox(width: 6),
            Text(
              'Add More Items',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _kioskCheckout(BuildContext context) async {
    final result = await showKioskCheckoutDialog(context);
    if (result != null && context.mounted) {
      Navigator.of(context).pop(result);
    }
  }

  void _confirmAndSubmitOrder(BuildContext context) {
    final tableState = context.read<TableBloc>().state;
    if (tableState is TableLoaded) {
      showDialog(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFFFAF7F2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              'Confirm Order',
              style: TextStyle(
                color: Color(0xFF1A1A1A),
                fontFamily: 'PTSerif',
                fontWeight: FontWeight.bold,
              ),
            ),
            content: const Text(
              'Are you ready to send your selected items to the kitchen?',
              style: TextStyle(
                color: Color(0xFF4A4A4A),
                fontSize: 14.5,
                height: 1.35,
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: <Widget>[
              TextButton(
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  'Confirm & Send',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  context.read<CartBloc>().add(
                    SubmitOrder(
                      tableId: tableState.table.tableId,
                      guestCount: 1,
                    ),
                  );
                },
              ),
            ],
          );
        },
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Table info not available'),
        ),
      );
    }
  }

  Widget _buildSummaryRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade700,
            fontSize: 13.5,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: Colors.grey.shade800,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
