import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/datasources/table_data_source.dart';
import '../../data/models/table_model.dart';
// Events and States are parts
part 'table_event.dart';
part 'table_state.dart';

class TableBloc extends Bloc<TableEvent, TableState> {
  final TableDataSource _dataSource;

  TableBloc(this._dataSource) : super(TableInitial()) {
    on<GetTable>(_onGetTable);
    on<GetTableByName>(_onGetTableByName);
    on<ResetTableState>(_onResetTableState);
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

  Future<void> _onGetTableByName(GetTableByName event, Emitter<TableState> emit) async {
    emit(TableLoading());
    try {
      final table = await _dataSource.getTableByName(event.name);
      emit(TableLoaded(table));
    } catch (e) {
      emit(TableError(e.toString()));
    }
  }

  void _onResetTableState(ResetTableState event, Emitter<TableState> emit) {
    emit(TableInitial());
  }
}
