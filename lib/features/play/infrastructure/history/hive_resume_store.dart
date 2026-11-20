import 'package:anime_flow/core/settings/storage.dart';
import 'package:anime_flow/features/play/application/resume_store.dart';
import 'package:hive_ce/hive.dart';

/// 用现有的 settings Box 存自有续播记录（值是 JSON 字符串）。
///
/// 单独开一个 Box 也行，但会多一个迁移面；settings Box 已经初始化好，
/// 键名带 `resume_v2_` 前缀，和别的设置互不干扰。
class HiveResumeStorage implements ResumeStorage {
  Box<dynamic>? get _box {
    try {
      return Storage.setting;
    } catch (_) {
      // Storage 还没初始化（极早期调用）时安静退化，不抛异常。
      return null;
    }
  }

  @override
  String? readRaw(String key) {
    final value = _box?.get(key);
    return value is String ? value : null;
  }

  @override
  Future<void> writeRaw(String key, String value) async {
    await _box?.put(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _box?.delete(key);
  }

  @override
  Iterable<String> keys() =>
      _box?.keys.whereType<String>().toList(growable: false) ?? const [];
}

/// 全局唯一实例。
final ResumeStore resumeStore = ResumeStore(HiveResumeStorage());
