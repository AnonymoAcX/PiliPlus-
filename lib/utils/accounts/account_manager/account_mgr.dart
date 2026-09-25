// edit from package:dio_cookie_manager
import 'dart:io';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/api_type.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

class AccountManager extends Interceptor {
  AccountManager();

  static String blockServer = Pref.blockServer;

  static String getCookies(List<Cookie> cookies) {
    // Sort cookies by path (longer path first).
    cookies.sort((a, b) {
      if (a.path == null && b.path == null) {
        return 0;
      } else if (a.path == null) {
        return -1;
      } else if (b.path == null) {
        return 1;
      } else {
        return b.path!.length.compareTo(a.path!.length);
      }
    });
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    // B 站域名缺失 user-agent 时补齐合理默认 (Http2Adapter 不会自动添加标头);
    // 不覆盖调用点显式指定的 UA, 也不影响非 B 站域名
    if (options.headers['user-agent'] == null &&
        options.uri.host.endsWith('bilibili.com')) {
      options.headers['user-agent'] = path.startsWith(HttpString.appBaseUrl)
          ? Constants.userAgentApp
          : Constants.userAgent;
    }
    // 记录请求起始时间, 供超时诊断计算实际耗时
    options.extra['_reqStart'] = DateTime.now().millisecondsSinceEpoch;

    final account = _bindRequestAccount(options);

    if (account is NoAccount || _skipCookie(path)) return handler.next(options);

    if (!account.isLogin && path == Api.heartBeat) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    final isApp = path.startsWith(HttpString.appBaseUrl);

    if (isApp && options.responseType == ResponseType.bytes) {
      options.headers.addAll(account.grpcHeaders);
      return handler.next(options);
    }

    options.headers
      ..addAll(account.headers)
      ..['referer'] ??= HttpString.baseUrl;

    // app端不需要管理cookie
    if (isApp) {
      // if (kDebugMode) debugPrint('is app: ${options.path}');
      final dataPtr = (options.method == 'POST' && options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : options.queryParameters);
      if (dataPtr.isNotEmpty) {
        if (!account.accessKey.isNullOrEmpty) {
          dataPtr['access_key'] = account.accessKey!;
        }
        AppSign.appSign(dataPtr..remove('sign'));
        // if (kDebugMode) debugPrint(dataPtr.toString());
      }
      return handler.next(options);
    } else {
      account.cookieJar
          .loadForRequest(options.uri)
          .then((cookies) {
            final previousCookies =
                options.headers[HttpHeaders.cookieHeader] as String?;
            final newCookies = getCookies([
              ...?previousCookies
                  ?.split(';')
                  .where((e) => e.isNotEmpty)
                  .map(Cookie.fromSetCookieValue),
              ...cookies,
            ]);
            options.headers[HttpHeaders.cookieHeader] = newCookies.isNotEmpty
                ? newCookies
                : '';
            handler.next(options);
          })
          .catchError((Object e, StackTrace s) {
            final err = DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            );
            handler.reject(err, true);
          });
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_boundRequestAccount(response.requestOptions) case final account?) {
      final future = _saveCookies(
        account,
        response,
      ).whenComplete(() => handler.next(response));
      assert(() {
        future.catchError(
          (Object e, StackTrace s) {
            throw DioException(
              requestOptions: response.requestOptions,
              error: e,
              stackTrace: s,
            );
          },
        );
        return true;
      }());
    } else {
      return handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }

    if (options.method != 'POST') toast(err);

    if (err.response case final res?) {
      if (_boundRequestAccount(options) case final account?) {
        _saveCookies(account, res).then(
          (_) => handler.next(err),
          onError: (Object e, StackTrace s) => handler.next(
            DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            ),
          ),
        );
        return;
      }
    }
    return handler.next(err);
  }

  static void toast(DioException err) {
    const skipShow = [
      'heartbeat',
      'history/report',
      'roomEntryAction',
      'seg.so',
      'online/total',
      'github',
      'hdslb.com',
      'biliimg.com',
      'site/getCoin',
      // 该接口失败只影响续播到上次分P/看点/字幕, 调用方已按 Success 优雅降级,
      // 播放不受影响, 不该再弹窗打扰用户。
      'player/wbi/v2',
    ];
    String url = err.requestOptions.uri.toString();
    if (kDebugMode) debugPrint('🌹🌹ApiInterceptor: $url\n$err');
    if (skipShow.any(url.contains) ||
        (url.contains('skipSegments') && err.requestOptions.method == 'GET')) {
      // skip
    } else {
      final type = err.type;
      final isNetIssue =
          type == DioExceptionType.connectionError ||
          type == DioExceptionType.connectionTimeout ||
          type == DioExceptionType.sendTimeout ||
          type == DioExceptionType.receiveTimeout;
      // 去重只作用于弹窗: kDebugMode 的 debugPrint 永远全量打印, 便于调试时看每次失败。
      if (isNetIssue) {
        final diag = diagnose(err);
        if (kDebugMode) debugPrint('🌹🌹诊断: $diag');
        if (!_firstToastFor(err.requestOptions.uri.path)) return;
        dioError(err).then((res) => SmartDialog.showToast('$res$url\n$diag'));
      } else {
        // 追加响应侧字段, 让「服务器异常」能自证来源: 非 2xx 的真实状态码、
        // 重定向后的最终地址、内容类型(区分 B 站 JSON 与劫持/WAF 的 text/html)与正文开头。
        if (!_firstToastFor(err.requestOptions.uri.path)) return;
        dioError(err).then(
          (res) => SmartDialog.showToast('$res$url${responseDiag(err)}'),
        );
      }
    }
  }

  /// 超时/连接类失败的可读诊断 (仅环境与耗时, 不含 cookie/token/csrf 等敏感值)
  static String diagnose(DioException err) {
    final options = err.requestOptions;
    final error = err.error;
    final ip = error is SocketException
        ? (error.address?.address ?? 'unknown')
        : 'unknown';
    final start = options.extra['_reqStart'];
    final elapsed = start is int
        ? '${DateTime.now().millisecondsSinceEpoch - start}ms'
        : 'unknown';
    final proxy = Pref.enableSystemProxy
        ? '${Pref.systemProxyHost}:${Pref.systemProxyPort}'
        : 'off';
    return '[诊断] host=${options.uri.host} ip=$ip '
        'proxy=$proxy http2=${Pref.enableHttp2} elapsed=$elapsed';
  }

  /// 同一接口路径本会话只提示一次, 避免每次进入页面都被同一个错误弹窗骚扰。
  /// 返回 true 表示该路径首次出现, 可以弹窗。
  static bool _firstToastFor(String path) => _toastedPaths.add(path);

  /// 已弹过窗的接口路径 (进程内, 不落盘)
  static final Set<String> _toastedPaths = <String>{};

  /// 非网络类失败 (badResponse 等) 的响应侧诊断。
  /// 仅含状态码/最终地址/内容类型/正文摘要, 不含请求头与 cookie/token/sessdata 等敏感值 (正文按 120 字符截断)。
  static String responseDiag(DioException err) {
    final res = err.response;
    final parts = <String>[];
    if (res != null) {
      final code = res.statusCode;
      if (code != null) parts.add('[HTTP $code]');
      final finalUri = err.requestOptions.uri.resolveUri(res.realUri);
      if (finalUri != err.requestOptions.uri) parts.add('final=$finalUri');
      final ct = res.headers.value('content-type');
      if (ct != null) parts.add('ct=$ct');
    }
    final msg = err.message;
    if (msg != null && msg.isNotEmpty) parts.add('msg=$msg');
    final data = res?.data;
    if (data != null) parts.add('body=${_bodySnippet(data)}');
    return parts.isEmpty ? '' : ' ${parts.join(' ')}';
  }

  /// 响应正文压成单行并截断, 防止长正文刷屏
  static String _bodySnippet(Object data) {
    final body = '$data'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return body.length > 120 ? body.substring(0, 120) : body;
  }

  static Future<void> _saveCookies(Account account, Response response) async {
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }
    final List<Cookie> cookies = setCookies
        .map((str) => str.split(_setCookieReg))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .map(Cookie.fromSetCookieValue)
        .toList();
    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? const [];
    final isRedirectRequest = statusCode >= 300 && statusCode < 400;
    final originalUri = response.requestOptions.uri;
    final realUri = originalUri.resolveUri(response.realUri);
    await account.cookieJar.saveFromResponse(realUri, cookies);
    if (isRedirectRequest && locations.isNotEmpty) {
      final originalUri = response.realUri;
      await Future.wait(
        locations.map(
          (location) => account.cookieJar.saveFromResponse(
            // Resolves the location based on the current Uri.
            originalUri.resolve(location),
            cookies,
          ),
        ),
      );
    }
    await account.onChange();
  }

  static bool _skipCookie(String path) {
    return path.startsWith(blockServer) ||
        path.contains('hdslb.com') ||
        path.contains('biliimg.com');
  }

  static Account _findAccount(String path) => ApiType.loginApi.contains(path)
      ? AnonymousAccount()
      : Accounts.get(
          AccountType.values.firstWhere(
            (i) => ApiType.apiTypeSet[i]?.contains(path) == true,
            orElse: () => AccountType.main,
          ),
        );

  static Account _bindRequestAccount(RequestOptions options) {
    assert(options.extra['account'] is Account?);
    return options.extra['account'] ??= _findAccount(options.path);
  }

  static Account? _boundRequestAccount(RequestOptions options) {
    final path = options.path;
    final account = options.extra['account'] as Account;
    if (account is NoAccount ||
        path.startsWith(HttpString.appBaseUrl) ||
        _skipCookie(path)) {
      return null;
    }
    return account;
  }

  static Future<String> dioError(DioException error) async {
    switch (error.type) {
      case .badCertificate:
        return '证书有误！';
      case .badResponse:
        return '服务器异常，请稍后重试！';
      case .cancel:
        return '请求已被取消，请重新请求';
      case .connectionError:
        return '连接错误，请检查网络设置';
      case .connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case .receiveTimeout:
        return '响应超时，请稍后重试！';
      case .sendTimeout:
        return '发送请求超时，请检查网络设置';
      case .transformTimeout:
        return '转换响应数据超时！';
      case .unknown:
        String desc;
        try {
          desc = PlatformUtils.isMobile
              ? (await Connectivity().checkConnectivity()).first.desc
              : '';
        } catch (_) {
          desc = '';
        }
        return '$desc网络异常 ${error.error}';
    }
  }
}

extension _ConnectivityResultExt on ConnectivityResult {
  String get desc => const ['蓝牙', 'Wi-Fi', '局域', '流量', '无', '代理', '其他'][index];
}
