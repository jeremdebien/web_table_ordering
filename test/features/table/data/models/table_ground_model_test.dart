import 'package:flutter_test/flutter_test.dart';
import 'package:web_table_ordering/features/table/data/models/ground_model.dart';
import 'package:web_table_ordering/features/table/data/models/table_model.dart';

void main() {
  group('GroundModel', () {
    test('should properly parse from JSON', () {
      final json = {
        "id": 1,
        "ground_desc": "Main Hall",
        "ground_status": 1,
        "created_at": "2023-10-27T10:00:00Z",
        "ground_id": 100,
      };

      final model = GroundModel.fromJson(json);

      expect(model.id, 1);
      expect(model.description, "Main Hall");
      expect(model.isActive, true);
      expect(model.createdAt, DateTime.parse("2023-10-27T10:00:00Z"));
      expect(model.groundId, 100);
    });

    test('should properly serialize to JSON', () {
      final model = GroundModel(
        id: 1,
        description: "Main Hall",
        isActive: true,
        createdAt: DateTime.parse("2023-10-27T10:00:00Z"),
        groundId: 100,
      );

      final json = model.toJson();

      expect(json['id'], 1);
      expect(json['ground_desc'], "Main Hall");
      expect(json['ground_status'], 1);
      expect(json['created_at'], "2023-10-27T10:00:00.000Z");
      expect(json['ground_id'], 100);
    });
  });

  group('TableModel', () {
    test('should properly parse from JSON', () {
      final json = {
        "id": 2,
        "table_id": 50,
        "table_uuid": "some-uuid-123",
        "table_desc": "Table 1",
        "table_status": 1,
        "ground_id": 100,
        "created_at": "2023-10-27T10:00:00Z",
      };

      final model = TableModel.fromJson(json);

      expect(model.id, 2);
      expect(model.tableId, 50);
      expect(model.uuid, "some-uuid-123");
      expect(model.description, "Table 1");
      expect(model.isActive, true);
      expect(model.groundId, 100);
      expect(model.createdAt, DateTime.parse("2023-10-27T10:00:00Z"));
    });

    test('should properly serialize to JSON', () {
      final model = TableModel(
        id: 2,
        tableId: 50,
        uuid: "some-uuid-123",
        description: "Table 1",
        isActive: true,
        groundId: 100,
        createdAt: DateTime.parse("2023-10-27T10:00:00Z"),
      );

      final json = model.toJson();

      expect(json['id'], 2);
      expect(json['table_id'], 50);
      expect(json['table_uuid'], "some-uuid-123");
      expect(json['table_desc'], "Table 1");
      expect(json['table_status'], 1);
      expect(json['ground_id'], 100);
      expect(json['created_at'], "2023-10-27T10:00:00.000Z");
    });
  });
}
