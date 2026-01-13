import 'package:flutter_test/flutter_test.dart';
import 'package:web_table_ordering/features/menu/data/models/department_model.dart';
import 'package:web_table_ordering/features/menu/data/models/category_model.dart';
import 'package:web_table_ordering/features/menu/data/models/item_model.dart';

void main() {
  group('DepartmentModel', () {
    test('should properly parse from JSON', () {
      final json = {
        "id": 1,
        "dept_name": "Food",
        "dept_description": "All food items",
        "status": true,
        "created_at": "2023-10-27T10:00:00Z",
        "updated_at": null,
        "dept_id": null,
      };

      final model = DepartmentModel.fromJson(json);

      expect(model.id, 1);
      expect(model.name, "Food");
      expect(model.description, "All food items");
      expect(model.isActive, true);
      expect(model.createdAt, DateTime.parse("2023-10-27T10:00:00Z"));
      expect(model.updatedAt, null);
      expect(model.deptId, null);
    });

    test('should properly serialize to JSON', () {
      final model = DepartmentModel(
        id: 1,
        name: "Food",
        description: "All food items",
        isActive: true,
        createdAt: DateTime.parse("2023-10-27T10:00:00Z"),
        updatedAt: null,
        deptId: null,
      );

      final json = model.toJson();

      expect(json['id'], 1);
      expect(json['dept_name'], "Food");
      expect(json['dept_description'], "All food items");
      expect(json['status'], true);
      expect(json['created_at'], "2023-10-27T10:00:00.000Z");
    });
  });

  group('CategoryModel', () {
    test('should properly parse from JSON', () {
      final json = {
        "id": 2,
        "department_id": 1,
        "category_name": "Burgers",
        "category_desc": "Delicious burgers",
        "status": true,
        "created_at": "2023-10-27T10:00:00Z",
        "updated_at": null,
        "category_id": null,
      };

      final model = CategoryModel.fromJson(json);

      expect(model.id, 2);
      expect(model.departmentId, 1);
      expect(model.name, "Burgers");
      expect(model.description, "Delicious burgers");
      expect(model.isActive, true);
      expect(model.createdAt, DateTime.parse("2023-10-27T10:00:00Z"));
    });

    test('should properly serialize to JSON', () {
      final model = CategoryModel(
        id: 2,
        departmentId: 1,
        name: "Burgers",
        description: "Delicious burgers",
        isActive: true,
        createdAt: DateTime.parse("2023-10-27T10:00:00Z"),
      );

      final json = model.toJson();

      expect(json['id'], 2);
      expect(json['department_id'], 1);
      expect(json['category_name'], "Burgers");
      expect(json['category_desc'], "Delicious burgers");
      expect(json['status'], true);
    });
  });

  group('ItemModel', () {
    test('should properly parse from JSON (status 1 = true)', () {
      final json = {
        "id": 3,
        "barcode": "123456789",
        "item_code": "BURGER01",
        "item_name": "Cheese Burger",
        "item_desc": "Yummy cheese",
        "item_status": 1,
        "print_desc": "Chz Bgr",
        "department_id": 1,
        "category_id": 2,
        "cost_price": 5.0,
        "mark_up": 2.0,
        "price": 10.0,
        "price_1": 11.0,
        "price_2": null,
        "price_3": null,
        "price_4": null,
        "price_5": null,
        "assigned_printer": "Kitchen",
        "is_disc_exempt": false,
        "is_non_vat": false,
        "display_image": "burger.jpg",
        "created_at": "2023-10-27T10:00:00Z",
        "update_at": null,
      };

      final model = ItemModel.fromJson(json);

      expect(model.id, 3);
      expect(model.isAvailable, true); // 1 maps to true
      expect(model.name, "Cheese Burger");
      expect(model.price, 10.0);
      expect(model.createdAt, DateTime.parse("2023-10-27T10:00:00Z"));
    });

    test('should properly parse from JSON (status 0 = false)', () {
      final json = {
        "id": 3,
        "barcode": "123456789",
        "item_code": "BURGER01",
        "item_name": "Cheese Burger",
        "item_desc": null,
        "item_status": 0,
        "print_desc": null,
        "department_id": 1,
        "category_id": 2,
        "cost_price": null,
        "mark_up": null,
        "price": 10.0,
        "price_1": null,
        "price_2": null,
        "price_3": null,
        "price_4": null,
        "price_5": null,
        "assigned_printer": null,
        "is_disc_exempt": false,
        "is_non_vat": false,
        "display_image": null,
        "created_at": "2023-10-27T10:00:00Z",
        "update_at": null,
      };

      final model = ItemModel.fromJson(json);
      expect(model.isAvailable, false); // 0 maps to false
    });

    test('should properly serialize to JSON', () {
      final model = ItemModel(
        id: 3,
        barcode: "123456789",
        itemCode: "BURGER01",
        name: "Cheese Burger",
        isAvailable: true,
        departmentId: 1,
        categoryId: 2,
        price: 10.0,
        createdAt: DateTime.parse("2023-10-27T10:00:00Z"),
      );

      final json = model.toJson();

      expect(json['id'], 3);
      expect(json['item_name'], "Cheese Burger");
      expect(json['item_status'], 1); // true maps to 1
      expect(json['created_at'], "2023-10-27T10:00:00.000Z");
    });
  });
}
