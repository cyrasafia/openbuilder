import 'package:dio/dio.dart';

/// Store 层操作失败。UI catch 后用 [friendlyError] 显示。
///
/// [toString] 用于日志（含 operation + 原始 cause 技术细节）；
/// UI 展示走 [friendlyError]，自动解包 [.cause] 转为友好文案。
class OperationException implements Exception {
  final String operation;
  final Object cause;
  const OperationException(this.operation, {required this.cause});

  @override
  String toString() => '$operation: $cause';
}

/// 将任意异常转换为用户可读的简短文案。
/// DioException 按 type / statusCode 分类；其他异常返回通用兜底。
String friendlyError(Object e) {
  if (e is OperationException) return friendlyError(e.cause);
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) return '认证失败，请检查服务器配置';
    if (code == 404) return '资源不存在';
    if (code != null && code >= 500) return '服务器错误，请稍后重试';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.transformTimeout:
        return '请求超时，请检查网络';
      case DioExceptionType.connectionError:
        return '无法连接到服务器';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badCertificate:
        return '证书错误';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }
  }
  if (e is StateError) return e.message;
  return '操作失败，请稍后重试';
}
