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
              ...items
                  .where((i) => i.originalQuantity > 0 && i.status == 'Pending')
                  .map((item) {
                    return OrderListItem(
                      item: item,
                      displayImage: getDisplayImage(item.itemBarcode),
                    );
                  }),
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
              ...items
                  .where(
                    (i) => i.originalQuantity > 0 && i.status == 'Cancelled',
                  )
                  .map((item) {
                    return OrderListItem(
                      item: item,
                      displayImage: getDisplayImage(item.itemBarcode),
                    );
                  }),
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
              ...items
                  .where(
                    (i) => i.originalQuantity > 0 && i.status == 'Accepted',
                  )
                  .map((item) {
                    return OrderListItem(
                      item: item,
                      displayImage: getDisplayImage(item.itemBarcode),
                    );
                  }),
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
              ...items.where((i) => i.originalQuantity == 0).map((item) {
                return OrderListItem(
                  item: item,
                  displayImage: getDisplayImage(item.itemBarcode),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
