class ApiConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://3.35.4.4/api',
  );
  static const String fileBaseUrl = String.fromEnvironment(
    'FILE_BASE_URL',
    defaultValue: 'http://3.35.4.4/files/',
  );

  // 기존 코드 호환용
  static const String baseUrl = apiBaseUrl;
  static const int devUserId = int.fromEnvironment(
    'DEV_USER_ID',
    defaultValue: 1,
  );
  static const bool enableAuthHeader = bool.fromEnvironment(
    'ENABLE_AUTH_HEADER',
    defaultValue: false,
  );

  static String api(String path) {
    final base = apiBaseUrl.endsWith('/')
        ? apiBaseUrl.substring(0, apiBaseUrl.length - 1)
        : apiBaseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return '$base$normalizedPath';
  }

  static String fileUrl(String path) {
    if (path.startsWith('http')) return path;

    final prefix = fileBaseUrl.endsWith('/') ? fileBaseUrl : '$fileBaseUrl/';
    var normalizedPath = path;
    while (normalizedPath.startsWith('/')) {
      normalizedPath = normalizedPath.substring(1);
    }
    if (normalizedPath.startsWith('files/')) {
      normalizedPath = normalizedPath.substring('files/'.length);
    }

    return '$prefix$normalizedPath';
  }
}
