import 'package:dio/dio.dart';

class ApiClient {
  static const String baseUrl = 'https://api.maharoapp.com';
  final Dio dio;

  /// [dio] is a test seam; the app uses the default client.
  ApiClient({Dio? dio}) : dio = dio ?? Dio(BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));
}
