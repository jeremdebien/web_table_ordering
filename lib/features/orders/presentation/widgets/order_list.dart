import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/sales_order_item_model.dart';
import '../../../menu/data/models/item_model.dart';
import '../../../menu/presentation/bloc/menu_bloc.dart';
import 'order_list_item.dart';

class OrderList extends StatelessWidget {
  final List<SalesOrderItemModel> items;

  const OrderList({
    super.key,
    required this.items,
  });
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Expanded(child: Center(child: Text('Your cart is empty')));
    }

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
      } catch (e) {
        return null;
      }
    }

    Widget buildGroupedItems(List<SalesOrderItemModel> groupedItems) {
      // Group by nickname
      final Map<String, List<SalesOrderItemModel>> multiGroups = {};
      for (var item in groupedItems) {
        final nick = item.nickname.isEmpty ? 'Unknown' : item.nickname;
        if (!multiGroups.containsKey(nick)) {
          multiGroups[nick] = [];
        }
        multiGroups[nick]!.add(item);
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: multiGroups.entries.map((entry) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.person, size: 14, color: Color(0xfff25125)),
                    const SizedBox(width: 4),
                    Text(
                      'Ordered by: ${entry.key}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xfff25125),
                      ),
                    ),
                  ],
                ),
              ),
              ...entry.value.map((item) {
                return OrderListItem(
                  item: item,
                  displayImage: getDisplayImage(item.itemBarcode),
                );
              }),
            ],
          );
        }).toList(),
      );
    }

    return Expanded(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pending Orders Section
            if (items.any(
              (i) => i.originalQuantity > 0 && i.status == 'Pending',
            )) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Pending Order:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
              ),
              buildGroupedItems(
                items.where((i) => i.originalQuantity > 0 && i.status == 'Pending').toList(),
              ),
              const Divider(),
            ],

            // Cancelled Orders Section
            if (items.any(
              (i) => i.originalQuantity > 0 && i.status == 'Cancelled',
            )) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Cancelled Order:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),
              buildGroupedItems(
                items.where((i) => i.originalQuantity > 0 && i.status == 'Cancelled').toList(),
              ),
              const Divider(),
            ],

            // Accepted Orders Section
            if (items.any(
              (i) => i.originalQuantity > 0 && i.status == 'Accepted',
            )) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Order:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ),
              buildGroupedItems(
                items.where((i) => i.originalQuantity > 0 && i.status == 'Accepted').toList(),
              ),
            ],

            // Divider if Accepted and New exist
            if (items.any(
                  (i) => i.originalQuantity > 0 && i.status == 'Accepted',
                ) &&
                items.any((i) => i.originalQuantity == 0))
              const Divider(),

            // New Items (Additional Order) Section
            if (items.any((i) => i.originalQuantity == 0)) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Additional Order:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                ),
              ),
              buildGroupedItems(
                items.where((i) => i.originalQuantity == 0).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
