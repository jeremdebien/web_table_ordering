import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:web_table_ordering/features/menu/presentation/bloc/menu_bloc.dart';
import 'package:web_table_ordering/features/orders/presentation/bloc/cart_bloc.dart';
import 'package:web_table_ordering/features/orders/data/models/sales_order_item_model.dart';
import 'package:web_table_ordering/features/table/presentation/bloc/table_bloc.dart';
import '../../../../features/orders/presentation/widgets/order_summary.dart';

class MenuPage extends StatefulWidget {
  const MenuPage({super.key});

  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> {
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadActiveOrder();
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

  @override
  Widget build(BuildContext context) {
    return BlocListener<TableBloc, TableState>(
      listener: (context, state) {
        if (state is TableLoaded) {
          context.read<CartBloc>().add(LoadActiveOrder(state.table.tableId));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          titleSpacing: 0,
          title: Row(
            children: [
              Image.asset('assets/images/logo.jpg', width: 80),
              SizedBox(width: 10),
              const Expanded(
                child: AutoSizeText(
                  'Browse our menu',
                  style: TextStyle(fontSize: 20, fontFamily: 'Marous'),
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  minFontSize: 10,
                ),
              ),
              SizedBox(width: 10),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _isSearching = !_isSearching;
                    if (!_isSearching) {
                      _searchQuery = '';
                      _searchController.clear();
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _isSearching ? Colors.red : const Color(0xfff25125),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isSearching ? Icons.close : Icons.search,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
              SizedBox(
                width: 10,
              ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: BlocBuilder<CartBloc, CartState>(
          builder: (context, state) {
            if (state.items.isEmpty) return const SizedBox.shrink();
            final totalCount = state.items.fold(
              0,
              (sum, item) => sum + item.quantity,
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: FloatingActionButton.extended(
                  backgroundColor: Colors.black,
                  onPressed: () => _showOrderSummary(context),
                  label: Text(
                    'View Order ($totalCount)',
                    style: TextStyle(color: Colors.white),
                  ),
                  icon: const Icon(Icons.shopping_cart, color: Colors.white),
                ),
              ),
            );
          },
        ),
        body: BlocBuilder<CartBloc, CartState>(
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
                  // Filter items based on search query
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
                              (item) => item.categoryId == state.selectedCategoryId,
                            )
                            .toList();

                  return Column(
                    children: [
                      // Search bar (visible when searching)
                      if (_isSearching)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 8.0,
                          ),
                          child: TextField(
                            controller: _searchController,
                            autofocus: true,
                            decoration: InputDecoration(
                              hintText: 'Search for items...',
                              prefixIcon: const Icon(
                                Icons.search,
                                color: Color(0xfff25125),
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Color(0xfff25125),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                  color: Color(0xfff25125),
                                  width: 2,
                                ),
                              ),
                            ),
                            onChanged: (value) {
                              setState(() {
                                _searchQuery = value;
                              });
                            },
                          ),
                        ),
                      // Category chips (hidden when searching)
                      if (!_isSearching)
                        SizedBox(
                          height: 50,
                          child: ListView.builder(
                            itemCount: state.categories.length,
                            scrollDirection: Axis.horizontal,
                            itemBuilder: (context, index) {
                              final category = state.categories[index];
                              final isSelected = category.categoryId == state.selectedCategoryId;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4.0,
                                ),
                                child: ChoiceChip(
                                  label: Text(category.name),
                                  labelStyle: TextStyle(
                                    color: isSelected ? Colors.white : Colors.black,
                                  ),
                                  selected: isSelected,
                                  showCheckmark: false,
                                  selectedColor: const Color(0xfff25125),
                                  backgroundColor: Colors.white,
                                  side: BorderSide(
                                    color: isSelected ? Colors.white : const Color(0xfff25125),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  onSelected: (selected) {
                                    if (selected) {
                                      context.read<MenuBloc>().add(
                                        SelectCategory(
                                          category.categoryId ?? 0,
                                        ),
                                      );
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      Divider(),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: displayItems.isEmpty
                              ? const Center(
                                  child: Text(
                                    'No items found',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                    ),
                                  ),
                                )
                              : GridView.builder(
                                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    childAspectRatio: 0.8,
                                    crossAxisSpacing: 10,
                                  ),
                                  itemCount: displayItems.length,
                                  itemBuilder: (context, index) {
                                    final item = displayItems[index];
                                    return GestureDetector(
                                      onTap: () {
                                        _showAddItemConfirmation(context, item);
                                      },
                                      child: Card(
                                        color: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          side: BorderSide(
                                            color: Colors.grey.shade300,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Expanded(
                                              child: item.displayImage != null && item.displayImage!.isNotEmpty
                                                  ? ClipRRect(
                                                      borderRadius: BorderRadius.only(
                                                        topLeft: Radius.circular(20),
                                                        topRight: Radius.circular(20),
                                                      ),
                                                      child: Image.network(
                                                        item.displayImage!,
                                                        fit: BoxFit.cover,
                                                      ),
                                                    )
                                                  : Center(
                                                      child: Image.asset(
                                                        'assets/images/logo.jpg',
                                                        color: Colors.grey,
                                                        colorBlendMode: BlendMode.lighten,
                                                      ),
                                                    ),
                                            ),

                                            Container(
                                              width: double.infinity,
                                              decoration: BoxDecoration(
                                                color: Color(0xfff25125),
                                                borderRadius: BorderRadius.only(
                                                  bottomLeft: Radius.circular(
                                                    20,
                                                  ),
                                                  bottomRight: Radius.circular(
                                                    20,
                                                  ),
                                                ),
                                              ),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                child: Column(
                                                  children: [
                                                    Text(
                                                      item.name,
                                                      textAlign: TextAlign.center,
                                                      style: const TextStyle(
                                                        fontFamily: 'FactorySansMedium',
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                    Text(
                                                      '₱${item.price}',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
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
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Expanded(child: OrderSummary()),
            ],
          ),
        );
      },
    );
  }

  void _showAddItemConfirmation(BuildContext context, dynamic item) {
    int quantity = 1;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.8,
                height: MediaQuery.of(context).size.height * 0.2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Confirm Order",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 15),
                    Row(
                      children: [
                        item.displayImage != null && item.displayImage!.isNotEmpty
                            ? Image.network(
                                item.displayImage!,
                                width: 100,
                                height: 100,
                                fit: BoxFit.cover,
                              )
                            : Center(
                                child: Image.asset(
                                  'assets/images/logo.jpg',
                                  width: 100,
                                  height: 100,
                                  color: Colors.grey,
                                  colorBlendMode: BlendMode.lighten,
                                ),
                              ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AutoSizeText(
                                item.name,
                                textAlign: TextAlign.left,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xfff25125),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 5),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.grey.shade300,
                                      ),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Row(
                                      children: [
                                        InkWell(
                                          onTap: () {
                                            if (quantity > 1) {
                                              setState(() {
                                                quantity--;
                                              });
                                            }
                                          },
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            child: Icon(Icons.remove, size: 16),
                                          ),
                                        ),
                                        Text(
                                          '$quantity',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        InkWell(
                                          onTap: () {
                                            setState(() {
                                              quantity++;
                                            });
                                          },
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            child: Icon(Icons.add, size: 16),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xfff25125),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Text(
                                        '₱${item.price}',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  style: TextButton.styleFrom(
                    side: BorderSide(color: Colors.grey.shade300),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xfff25125),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    context.read<CartBloc>().add(
                      AddToCart(
                        SalesOrderItemModel(
                          itemBarcode: item.barcode,
                          itemName: item.name,
                          quantity: quantity,
                          amount: item.price,
                          originalQuantity: 0,
                        ),
                      ),
                    );
                  },
                  child: const Text('Add to Order'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
