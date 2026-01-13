import 'package:flutter_bloc/flutter_bloc.dart';
import '../../data/models/table_model.dart';
import '../../data/datasources/table_supabase_datasource.dart';

abstract class TableContextState {}

class TableContextInitial extends TableContextState {}

class TableContextLoading extends TableContextState {}

class TableContextLoaded extends TableContextState {
  final TableModel table;
  TableContextLoaded(this.table);
}

class TableContextError extends TableContextState {
  final String message;
  TableContextError(this.message);
}

class TableContextCubit extends Cubit<TableContextState> {
  final TableSupabaseDataSource _dataSource;

  TableContextCubit(this._dataSource) : super(TableContextInitial());

  Future<void> loadTable(String uuid) async {
    emit(TableContextLoading());
    try {
      final table = await _dataSource.getTableByUuid(uuid);
      emit(TableContextLoaded(table));
    } catch (e) {
      emit(TableContextError(e.toString()));
    }
  }
}
