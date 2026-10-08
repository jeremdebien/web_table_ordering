import '../models/ground_model.dart';
import '../models/layout_item_model.dart';
import '../models/table_model.dart';

/// Read contract for table lookup, implemented per app mode.
abstract class TableDataSource {
  Future<TableModel> getTableByUuid(String uuid);
  Future<TableModel> getTableByName(String name);

  /// All active grounds (floors/sections). Local-mode only for now — the online
  /// impl throws, as the hosted staff floor-plan is not yet wired.
  Future<List<GroundModel>> getGrounds();

  /// All active tables across every ground, each carrying its `groundId` and
  /// floor-plan layout fields. Local-mode only for now.
  Future<List<TableModel>> getTables();

  /// Blueprint structures (walls, doors, text, areas, markers …) across every
  /// ground. Local-mode only for now.
  Future<List<LayoutItemModel>> getLayoutItems();
}
