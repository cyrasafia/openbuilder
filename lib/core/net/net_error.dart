import 'package:dio/dio.dart';

import '../../l10n/gen/app_localizations.dart';

class OperationException implements Exception {
  final String operation;
  final Object cause;
  const OperationException(this.operation, {required this.cause});

  @override
  String toString() => '$operation: $cause';
}

enum FriendlyErrorKind {
  authFailed,
  notFound,
  serverError,
  timeout,
  connect,
  cancelled,
  badCert,
  sessionNotReady,
  notConnected,
  generic,
}

class KnownError implements Exception {
  final FriendlyErrorKind kind;
  const KnownError(this.kind);
}

FriendlyErrorKind friendlyErrorRaw(Object e) {
  if (e is KnownError) return e.kind;
  if (e is OperationException) return friendlyErrorRaw(e.cause);
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) return FriendlyErrorKind.authFailed;
    if (code == 404) return FriendlyErrorKind.notFound;
    if (code != null && code >= 500) return FriendlyErrorKind.serverError;
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.transformTimeout =>
        FriendlyErrorKind.timeout,
      DioExceptionType.connectionError => FriendlyErrorKind.connect,
      DioExceptionType.cancel => FriendlyErrorKind.cancelled,
      DioExceptionType.badCertificate => FriendlyErrorKind.badCert,
      DioExceptionType.badResponse || DioExceptionType.unknown =>
        FriendlyErrorKind.generic,
    };
  }
  return FriendlyErrorKind.generic;
}

String friendlyMessage(AppLocalizations l, Object e) {
  if (e is String) return e;
  return switch (friendlyErrorRaw(e)) {
    FriendlyErrorKind.authFailed => l.errorAuthFailed,
    FriendlyErrorKind.notFound => l.errorNotFound,
    FriendlyErrorKind.serverError => l.errorServerError,
    FriendlyErrorKind.timeout => l.errorTimeout,
    FriendlyErrorKind.connect => l.errorConnect,
    FriendlyErrorKind.cancelled => l.errorCancelled,
    FriendlyErrorKind.badCert => l.errorBadCert,
    FriendlyErrorKind.sessionNotReady => l.errorSessionNotReady,
    FriendlyErrorKind.notConnected => l.errorNotConnected,
    FriendlyErrorKind.generic => l.errorGeneric,
  };
}
