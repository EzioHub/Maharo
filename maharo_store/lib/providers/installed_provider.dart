import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/package_service.dart';

final installedVersionProvider = FutureProvider.family<InstalledAppInfo?, String>((ref, packageName) async {
  return PackageService.getInstalledVersion(packageName);
});
