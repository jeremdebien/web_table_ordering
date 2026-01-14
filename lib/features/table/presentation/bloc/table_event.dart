part of 'table_bloc.dart';

abstract class TableEvent extends Equatable {
  const TableEvent();

  @override
  List<Object?> get props => [];
}

class GetTable extends TableEvent {
  final String uuid;

  const GetTable(this.uuid);

  @override
  List<Object?> get props => [uuid];
}
