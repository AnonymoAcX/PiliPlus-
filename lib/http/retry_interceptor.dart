import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  /// 重试前强制重建连接池 (丢弃死 socket), 见 Request._resetAdaptersForNetworkChange
  final void Function()? _resetConnections;

  RetryInterceptor(
    this._client,
    this._count,
    this._delay, [
    this._resetConnections,
  ]);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = options.uri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      switch (err.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.unknown:
          if ((err.requestOptions.extra['_rt'] ??= 0) < _count &&
              err.error
                  is! TransportConnectionException // 网络中断, 此时请求可能已经被服务器所接收
              &&
              // 响应超时时请求可能已被服务端处理, 默认仅幂等 GET 重试(重连会重新解析DNS换边缘节点);
              // 调用点可用 extra['_retryTimeout'] == true 显式声明该 POST 为绝对语义/可安全重放
              // (如 B 站关系类 act: follow/unfollow/block 为绝对值), 未声明的一律不重试
              (err.type != DioExceptionType.receiveTimeout ||
                  err.requestOptions.method == 'GET' ||
                  err.requestOptions.extra['_retryTimeout'] == true)) {
            Timer(
              Duration(
                milliseconds: ++err.requestOptions.extra['_rt'] * _delay,
              ),
              () {
                // 重试前强制新建连接, 避免在死 socket 上重试仍拿到同一坏连接
                _resetConnections?.call();
                _client
                    .fetch(err.requestOptions)
                    .then(handler.resolve)
                    .onError<DioException>((error, _) => handler.reject(error));
              },
            );
          } else {
            handler.next(err);
          }
          return;
        default:
          return handler.next(err);
      }
    }
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      .new(
        client ?? _client,
        count ?? _count,
        delay ?? _delay,
        _resetConnections,
      );
}
