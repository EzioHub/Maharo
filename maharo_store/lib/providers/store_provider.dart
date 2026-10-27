import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../models/store_patch.dart';
import '../models/store_version.dart';
import '../models/store_app.dart';

final apiClientProvider = Provider((ref) => ApiClient());

// Network and parse errors propagate as AsyncError so the UI can show a
// retryable failure instead of silently rendering "nothing available".

/// The app's listing, or null when the store does not list it.
final appInfoProvider = FutureProvider.family<StoreApp?, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final response = await api.dio.get('/store/apps');
  final data = response.data;
  if (data is! List) {
    throw const FormatException('Unexpected /store/apps response');
  }
  for (final raw in data) {
    if (raw is Map<String, dynamic>) {
      final app = StoreApp.fromJson(raw);
      if (app.packageName == id || app.id == id) return app;
    }
  }
  return null;
});

/// The latest published version, or null when none is published (HTTP 404).
final latestVersionProvider = FutureProvider.family<StoreVersion?, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  try {
    final response = await api.dio.get('/store/apps/$id/latest');
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Unexpected latest-version response');
    }
    return StoreVersion.fromJson(data);
  } on DioException catch (e) {
    if (e.response?.statusCode == 404) return null;
    rethrow;
  }
});

final versionsProvider = FutureProvider.family<List<StoreVersion>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final response = await api.dio.get('/store/apps/$id/versions');
  final data = response.data;
  if (data is! List) {
    throw const FormatException('Unexpected versions response');
  }
  return data.whereType<Map<String, dynamic>>().map(StoreVersion.fromJson).toList();
});

/// Delta patch from the installed versionCode to the latest version, or null
/// when the API has none. Errors propagate; the update flow then falls back
/// to the full download.
final patchProvider = FutureProvider.family<StorePatch?, ({String appId, int fromVersionCode})>((ref, args) async {
  final api = ref.read(apiClientProvider);
  final response = await api.dio.get(
    '/store/apps/${args.appId}/patch',
    queryParameters: {'from': args.fromVersionCode},
  );
  final data = response.data;
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Unexpected patch response');
  }
  final patch = data['patch'];
  if (patch == null) return null;
  if (patch is! Map<String, dynamic>) {
    throw const FormatException('Unexpected patch payload');
  }
  return StorePatch.fromJson(patch);
});
