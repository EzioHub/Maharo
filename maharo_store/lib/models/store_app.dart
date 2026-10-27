class StoreApp {
  final String id;
  final String name;
  final String packageName;
  final String description;
  final String? descriptionEn;
  final String? iconUrl;

  StoreApp({
    required this.id,
    required this.name,
    required this.packageName,
    required this.description,
    this.descriptionEn,
    this.iconUrl,
  });

  factory StoreApp.fromJson(Map<String, dynamic> json) {
    return StoreApp(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      packageName: json['packageName'] ?? '',
      description: json['description'] ?? '',
      descriptionEn: json['descriptionEn'],
      iconUrl: json['iconUrl'],
    );
  }
}
