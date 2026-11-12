import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 设备互联传输层（局域网 HTTP）。
///
/// 对上提供 start / stop / configure / poll / respond / probe / allow /
/// request / cancel / disconnect 命令，由 [LanController] 通过
/// `repository.lan(...)` 调用。
///
/// 协议：
/// - `GET  /lan/v1/info`          返回设备信息（用于手动地址连接）
/// - `POST /lan/v1/<path>`        正文 `{deviceId, pin, payload}`；
///   `pair` 以外的路径必须带请求头 `X-Lan-Token`（由 allow 发出的令牌）
///
/// 说明：数据在局域网内以明文 HTTP 传输，令牌仅用于区分已连接设备。
class LanTransport {
  LanTransport({Future<String> Function()? identityDirectory})
    : _identityDirectory = identityDirectory ?? _defaultIdentityDirectory;

  final Future<String> Function() _identityDirectory;

  static Future<String> _defaultIdentityDirectory() async {
    try {
      final dir = await getApplicationSupportDirectory().timeout(
        const Duration(seconds: 2),
      );
      return dir.path;
    } catch (_) {
      return p.join(Directory.systemTemp.path, 'florist_tv');
    }
  }

  static const _maxBody = 16 * 1024 * 1024;
  static const _eventTimeout = Duration(seconds: 90);
  static const _requestTimeout = Duration(seconds: 60);

  String _deviceId = '';
  String _pin = '';
  _Session? _session;
  final Map<String, HttpClientRequest> _inflight = {};

  Future<Map<String, dynamic>> handle(
    String command,
    Map<String, dynamic> input,
  ) async {
    switch (command) {
      case 'start':
        return _start(_map(input['config']));
      case 'stop':
        await _stop(input['generation']);
        return {};
      case 'configure':
        _active(input['generation']).config = _map(input['config']);
        return {};
      case 'poll':
        return _poll(_active(input['generation']));
      case 'respond':
        _respond(_active(input['generation']), input);
        return {};
      case 'probe':
        return _probe(_active(input['generation']), input);
      case 'allow':
        return _allow(_active(input['generation']), input);
      case 'request':
        return _request(_active(input['generation']), input);
      case 'cancel':
        _inflight.remove(input['requestId'])?.abort();
        return {};
      case 'disconnect':
        final session = _session;
        if (session != null && session.generation == input['generation']) {
          session.grants.clear();
        }
        return {};
    }
    throw UnsupportedError('不支持的设备互联命令：$command');
  }

  Map<String, dynamic> _map(Object? value) {
    if (value is! Map) throw const FormatException('设备互联参数无效');
    return Map<String, dynamic>.from(value);
  }

  _Session _active(Object? generation) {
    final session = _session;
    if (session == null || session.generation != generation) {
      throw StateError('设备互联已停止');
    }
    return session;
  }

  String _random(int bytes) {
    final random = Random.secure();
    return List.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _loadIdentity() async {
    if (_deviceId.isNotEmpty) return;
    File? file;
    try {
      final directory = Directory(await _identityDirectory());
      await directory.create(recursive: true);
      file = File(p.join(directory.path, 'lan_identity.json'));
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map &&
            RegExp(r'^[a-f0-9]{32}$').hasMatch('${data['id']}') &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch('${data['pin']}')) {
          _deviceId = '${data['id']}';
          _pin = '${data['pin']}';
          return;
        }
      }
    } catch (_) {}
    _deviceId = _random(16);
    _pin = sha256.convert(utf8.encode('${_random(32)}:$_deviceId')).toString();
    try {
      await file?.writeAsString(jsonEncode({'id': _deviceId, 'pin': _pin}));
    } catch (_) {}
  }

  Future<List<String>> _addresses(int port) async {
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          result.add('${address.address}:$port');
        }
      }
    } catch (_) {}
    return result;
  }

  Map<String, dynamic> _info(_Session session, List<String> addresses) => {
    'deviceId': _deviceId,
    'name': '${session.config['name'] ?? ''}',
    'pin': _pin,
    'kind': '${session.config['kind'] ?? 'computer'}',
    'port': session.server.port,
    'addresses': addresses,
    'protocol': 1,
  };

  Future<Map<String, dynamic>> _start(Map<String, dynamic> config) async {
    await _loadIdentity();
    await _stop(null);
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final session = _Session(_random(16), server, config);
    _session = session;
    server.listen(
      (request) => unawaited(_serve(session, request)),
      onError: (Object _) {},
      cancelOnError: false,
    );
    final addresses = await _addresses(server.port);
    return {'generation': session.generation, ..._info(session, addresses)};
  }

  Future<void> _stop(Object? generation) async {
    final session = _session;
    if (session == null) return;
    if (generation != null && session.generation != generation) return;
    _session = null;
    for (final request in _inflight.values.toList()) {
      request.abort();
    }
    _inflight.clear();
    session.close();
  }

  Future<Map<String, dynamic>> _poll(_Session session) async {
    if (session.events.isNotEmpty) {
      return {'event': session.events.removeAt(0)};
    }
    final waiter = Completer<void>();
    session.waiter = waiter;
    await waiter.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {},
    );
    if (identical(session.waiter, waiter)) session.waiter = null;
    if (_session != session) throw StateError('设备互联已停止');
    if (session.events.isEmpty) return {};
    return {'event': session.events.removeAt(0)};
  }

  void _respond(_Session session, Map<String, dynamic> input) {
    final pending = session.pending.remove(input['eventId']);
    if (pending == null || pending.isCompleted) return;
    final error = '${input['error'] ?? ''}';
    if (error.isNotEmpty) {
      pending.complete({'error': error});
    } else {
      pending.complete({'payload': input['payload'] ?? {}});
    }
  }

  Map<String, dynamic> _allow(_Session session, Map<String, dynamic> input) {
    final token = _random(32);
    session.grants[token] = (
      deviceId: '${input['deviceId']}',
      pin: '${input['pin']}',
    );
    if (session.grants.length > 64) {
      session.grants.remove(session.grants.keys.first);
    }
    return {'token': token};
  }

  Future<void> _serve(_Session session, HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 3 || segments[0] != 'lan' || segments[1] != 'v1') {
        return _reply(request, 404, {'error': '未找到'});
      }
      final path = segments.sublist(2).join('/');
      if (request.method == 'GET' && path == 'info') {
        final addresses = await _addresses(session.server.port);
        return _reply(request, 200, {
          'payload': _info(session, addresses),
          'deviceId': _deviceId,
          'pin': _pin,
        });
      }
      if (request.method != 'POST') {
        return _reply(request, 405, {'error': '方法不允许'});
      }
      if (request.contentLength > _maxBody) {
        return _reply(request, 413, {'error': '数据过大'});
      }
      final bytes = BytesBuilder(copy: false);
      var size = 0;
      await for (final chunk in request) {
        size += chunk.length;
        if (size > _maxBody) {
          return _reply(request, 413, {'error': '数据过大'});
        }
        bytes.add(chunk);
      }
      final body = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (body is! Map) return _reply(request, 400, {'error': '请求格式无效'});
      String peerId;
      String peerPin;
      if (path == 'pair') {
        peerId = '${body['deviceId']}';
        peerPin = '${body['pin']}';
      } else {
        final grant = session.grants['${request.headers.value('X-Lan-Token')}'];
        if (grant == null) {
          return _reply(request, 401, {'error': '请先连接此设备'});
        }
        peerId = grant.deviceId;
        peerPin = grant.pin;
      }
      final id = _random(16);
      final completer = Completer<Map<String, dynamic>>();
      session.pending[id] = completer;
      session.events.add({
        'id': id,
        'path': path,
        'peerId': peerId,
        'pin': peerPin,
        'host': request.connectionInfo?.remoteAddress.address ?? '',
        'payload': body['payload'] ?? {},
      });
      final waiter = session.waiter;
      session.waiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      final result = await completer.future.timeout(
        _eventTimeout,
        onTimeout: () => {'error': '对方处理超时'},
      );
      session.pending.remove(id);
      final failed = result['error'] != null;
      return _reply(request, failed ? 409 : 200, {
        ...result,
        'deviceId': _deviceId,
        'pin': _pin,
      });
    } catch (error) {
      try {
        await _reply(request, 500, {'error': '$error'});
      } catch (_) {}
    }
  }

  Future<void> _reply(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Uri _uri(String address, String path) {
    if (!RegExp(r'^(\[[0-9a-fA-F:.%a-z]+\]|[A-Za-z0-9.\-]+):\d{1,5}$')
        .hasMatch(address)) {
      throw const FormatException('设备地址格式无效，应为 地址:端口');
    }
    return Uri.parse('http://$address/lan/v1/$path');
  }

  Future<Map<String, dynamic>> _fetch(
    _Session session,
    String requestId,
    Uri uri, {
    Map<String, dynamic>? body,
    String? token,
    String? expectPin,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.openUrl(body == null ? 'GET' : 'POST', uri);
      _inflight[requestId] = request;
      request.headers.contentType = ContentType.json;
      if (token != null && token.isNotEmpty) {
        request.headers.set('X-Lan-Token', token);
      }
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close().timeout(_requestTimeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      final data = jsonDecode(text);
      if (data is! Map) throw StateError('对方返回的数据无效');
      if (expectPin != null && expectPin.isNotEmpty && data['pin'] != expectPin) {
        throw StateError('设备身份不一致，已拒绝连接');
      }
      if (response.statusCode != 200) {
        throw StateError('${data['error'] ?? '设备返回错误 ${response.statusCode}'}');
      }
      final payload = data['payload'];
      return payload is Map ? Map<String, dynamic>.from(payload) : {};
    } on HttpException {
      throw StateError('请求已取消或连接被中断');
    } finally {
      _inflight.remove(requestId);
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _probe(
    _Session session,
    Map<String, dynamic> input,
  ) {
    return _fetch(
      session,
      '${input['requestId']}',
      _uri('${input['address']}', 'info'),
    );
  }

  Future<Map<String, dynamic>> _request(
    _Session session,
    Map<String, dynamic> input,
  ) {
    final path = '${input['path']}';
    if (!RegExp(r'^[a-z]+(/[a-z0-9_\-]+)*$').hasMatch(path)) {
      throw const FormatException('设备请求路径无效');
    }
    return _fetch(
      session,
      '${input['requestId']}',
      _uri('${input['address']}', path),
      body: {'deviceId': _deviceId, 'pin': _pin, 'payload': input['payload']},
      token: input['token'] as String?,
      expectPin: input['pin'] as String?,
    );
  }
}

class _Session {
  _Session(this.generation, this.server, this.config);

  final String generation;
  final HttpServer server;
  Map<String, dynamic> config;
  final List<Map<String, dynamic>> events = [];
  final Map<String, Completer<Map<String, dynamic>>> pending = {};
  final Map<String, ({String deviceId, String pin})> grants = {};
  Completer<void>? waiter;

  void close() {
    server.close(force: true);
    for (final completer in pending.values) {
      if (!completer.isCompleted) completer.complete({'error': '设备互联已停止'});
    }
    pending.clear();
    final current = waiter;
    waiter = null;
    if (current != null && !current.isCompleted) current.complete();
  }
}
