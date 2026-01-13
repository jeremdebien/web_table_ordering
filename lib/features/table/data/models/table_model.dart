class TableModel {
  final String uuid;
  final String code; // Display name/number
  final int groundId;

  TableModel({required this.uuid, required this.code, required this.groundId});

  factory TableModel.fromJson(Map<String, dynamic> json) {
    return TableModel(uuid: json['uuid'] as String, code: json['code'] as String, groundId: json['ground_id'] as int);
  }

  Map<String, dynamic> toJson() {
    return {'uuid': uuid, 'code': code, 'ground_id': groundId};
  }
}
