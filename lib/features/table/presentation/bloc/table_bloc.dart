import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/datasources/table_supabase_datasource.dart';
import '../../data/models/table_model.dart';
// Events and States are parts
part 'table_event.dart';
part 'table_state.dart';

class TableBloc extends Bloc<TableEvent, TableState> {
  final TableSupabaseDataSource _dataSource;

  TableBloc(this._dataSource) : super(TableInitial()) {
    on<GetTable>(_onGetTable);
  }

  Future<void> _onGetTable(GetTable event, Emitter<TableState> emit) async {
    emit(TableLoading());
    try {
      final table = await _dataSource.getTableByUuid(event.uuid);
      emit(TableLoaded(table));
    } catch (e) {
      emit(TableError(e.toString()));
    }
  }
}
