import '../models/table_model.dart';

/// Read contract for table lookup, implemented per app mode.
abstract class TableDataSource {
  Future<TableModel> getTableByUuid(String uuid);
}
