class StoreVersion {
  final String id;
  final String versionName;
  final int versionCode;
  final String changelog;
  final String changelogEn;
  final String downloadUrl;
  final int fileSizeBytes;
  final String sha256;
  final DateTime createdAt;

  StoreVersion({
    required this.id,
    required this.versionName,
    required this.versionCode,
    required this.changelog,
    required this.changelogEn,
    required this.downloadUrl,
    required this.fileSizeBytes,
    required this.sha256,
    required this.createdAt,
  });

  factory StoreVersion.fromJson(Map<String, dynamic> json) {
    return StoreVersion(
      id: json['id'] ?? '',
      versionName: json['versionName'] ?? '',
      versionCode: json['versionCode'] ?? 0,
      changelog: json['changelog'] ?? '',
      changelogEn: json['changelogEn'] ?? '',
      downloadUrl: json['downloadUrl'] ?? '',
      fileSizeBytes: json['fileSizeBytes'] ?? 0,
      sha256: json['sha256'] ?? '',
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    );
  }
}
