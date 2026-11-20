import 'dart:convert';

import 'package:anime_flow/core/settings/storage.dart';
import 'package:anime_flow/features/play/infrastructure/history/hive_resume_store.dart';
import 'package:http/http.dart' as http;

/// 你自己的 WebDAV 配置（坚果云 / Nextcloud / 群晖都行）。
///
/// 只用来放一个几 KB 的 JSON，不涉及任何第三方账号。
class WebDavConfig {
  static const String _urlKey = 'webdav_url';
  static const String _userKey = 'webdav_user';
  static const String _passKey = 'webdav_pass';

  final String url;
  final String username;
  final String password;

  const WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
  });

  bool get isConfigured => url.trim().isNotEmpty;

  static WebDavConfig load() {
    try {
      final box = Storage.setting;
      return WebDavConfig(
        url: '${box.get(_urlKey) ?? ''}',
        username: '${box.get(_userKey) ?? ''}',
        password: '${box.get(_passKey) ?? ''}',
      );
    } catch (_) {
      return const WebDavConfig(url: '', username: '', password: '');
    }
  }

  Future<void> save() async {
    final box = Storage.setting;
    await box.put(_urlKey, url.trim());
    await box.put(_userKey, username.trim());
    await box.put(_passKey, password);
  }

  Future<void> clear() async {
    final box = Storage.setting;
    await box.delete(_urlKey);
    await box.delete(_userKey);
    await box.delete(_passKey);
  }

  /// 备份文件地址：把配置的目录当文件夹，文件固定叫这个名字。
  Uri get fileUri {
    final base = url.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/animeflow-resume.json');
  }

  Map<String, String> get headers => {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        'Content-Type': 'application/json; charset=utf-8',
      };
}

class WebDavResult {
  final bool ok;
  final String message;

  const WebDavResult(this.ok, this.message);

  static const WebDavResult skipped =
      WebDavResult(false, '还没配置 WebDAV');
}

class WebDavSync {
  WebDavSync._();
  static final WebDavSync instance = WebDavSync._();

  static const Duration _timeout = Duration(seconds: 20);
  DateTime? _lastPush;

  /// 上传：把本机全部续播记录写成一个 JSON 推到你的网盘。
  Future<WebDavResult> push() async {
    final config = WebDavConfig.load();
    if (!config.isConfigured) return WebDavResult.skipped;
    final client = http.Client();
    try {
      final body = resumeStore.exportJson();
      final response = await client
          .put(config.fileUri, headers: config.headers, body: body)
          .timeout(_timeout);
      _lastPush = DateTime.now();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return WebDavResult(true, '已上传（${body.length} 字节）');
      }
      return WebDavResult(
        false,
        '上传失败 HTTP ${response.statusCode}（检查目录是否存在、账号是否有写权限）',
      );
    } catch (e) {
      return WebDavResult(false, '上传失败：$e');
    } finally {
      client.close();
    }
  }

  /// 下载并合并：同一条目按更新时间取新，同集取播放更靠后的位置。
  Future<WebDavResult> pull() async {
    final config = WebDavConfig.load();
    if (!config.isConfigured) return WebDavResult.skipped;
    final client = http.Client();
    try {
      final response = await client
          .get(config.fileUri, headers: config.headers)
          .timeout(_timeout);
      if (response.statusCode == 404) {
        return const WebDavResult(true, '远端还没有备份，先上传一次即可');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return WebDavResult(false, '下载失败 HTTP ${response.statusCode}');
      }
      final changed = await resumeStore.mergeFromJson(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      return WebDavResult(true, changed == 0 ? '已是最新' : '已合并 $changed 条');
    } catch (e) {
      return WebDavResult(false, '下载失败：$e');
    } finally {
      client.close();
    }
  }

  /// 播放过程中自动上传，节流到 90 秒一次，避免每 3 秒一次写网盘。
  Future<void> pushThrottled() async {
    final last = _lastPush;
    if (last != null && DateTime.now().difference(last).inSeconds < 90) {
      return;
    }
    _lastPush = DateTime.now();
    await push();
  }
}
