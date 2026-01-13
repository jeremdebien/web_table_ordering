class GroundModel {
  final int id;
  final String name;

  GroundModel({required this.id, required this.name});

  factory GroundModel.fromJson(Map<String, dynamic> json) {
    return GroundModel(id: json['id'] as int, name: json['name'] as String);
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name};
  }
}
