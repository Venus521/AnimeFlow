import 'dart:convert';

/// 一条「自有」续播记录。
///
/// 和 App 原有的 PlayHistory 不是一回事：它只由播放器状态写入，
/// 不参与作者服务器的云同步，也不会被「封面为空 / 时长为空」这类守卫丢弃。
/// 目的很直接——把续播这件事从那条六层链路里摘出来，自己管自己。
class ResumeEntry {
  final int subjectId;
  final int episodeId;
  final int episodeSort;
  final int positionSeconds;
  final int durationSeconds;
  final String? website;
  final DateTime updatedAt;

  const ResumeEntry({
    required this.subjectId,
    required this.episodeId,
    required this.episodeSort,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAt,
    this.website,
  });

  /// 这条记录是不是用户要续的那一集。
  ///
  /// 集 ID 优先；集 ID 对不上时用集数兜底（换源、剧集表变动都会让集 ID 变）。
  bool matches({required int episodeId, num? episodeSort}) {
    if (this.episodeId == episodeId) return true;
    return episodeSort != null &&
        episodeSort > 0 &&
        episodeSort == this.episodeSort;
  }

  Map<String, dynamic> toJson() => {
        'subjectId': subjectId,
        'episodeId': episodeId,
        'episodeSort': episodeSort,
        'position': positionSeconds,
        'duration': durationSeconds,
        'website': website,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static ResumeEntry? fromJson(Map<String, dynamic> json) {
    final subjectId = _asInt(json['subjectId']);
    final episodeId = _asInt(json['episodeId']);
    if (subjectId <= 0 || episodeId <= 0) return null;
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    final rawWebsite = json['website'];
    final website =
        rawWebsite is String && rawWebsite.trim().isNotEmpty
            ? rawWebsite.trim()
            : null;
    return ResumeEntry(
      subjectId: subjectId,
      episodeId: episodeId,
      episodeSort: _asInt(json['episodeSort']),
      positionSeconds: _asInt(json['position']),
      durationSeconds: _asInt(json['duration']),
      website: website,
      updatedAt: updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  String encode() => jsonEncode(toJson());

  static ResumeEntry? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? fromJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 0;
  }
}

/// 存储抽象：生产用 Hive，测试用内存。
abstract class ResumeStorage {
  String? readRaw(String key);
  Future<void> writeRaw(String key, String value);
  Future<void> delete(String key);
  Iterable<String> keys();
}

/// 续播记录的读写与合并。
class ResumeStore {
  ResumeStore(this._storage);

  final ResumeStorage _storage;
  static const String keyPrefix = 'resume_v2_';

  ResumeEntry? read(int subjectId) {
    final raw = _storage.readRaw('$keyPrefix$subjectId');
    return raw == null ? null : ResumeEntry.decode(raw);
  }

  Future<void> write(ResumeEntry entry) =>
      _storage.writeRaw('$keyPrefix${entry.subjectId}', entry.encode());

  List<ResumeEntry> all() {
    final result = <ResumeEntry>[];
    for (final key in _storage.keys()) {
      if (!key.startsWith(keyPrefix)) continue;
      final raw = _storage.readRaw(key);
      final entry = raw == null ? null : ResumeEntry.decode(raw);
      if (entry != null) result.add(entry);
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  Future<void> replaceAll(Iterable<ResumeEntry> entries) async {
    await clear();
    for (final entry in entries) {
      await write(entry);
    }
  }

  Future<void> clear() async {
    for (final key in _storage.keys().toList(growable: false)) {
      if (key.startsWith(keyPrefix)) await _storage.delete(key);
    }
  }

  String exportJson() => jsonEncode({
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'entries': [for (final entry in all()) entry.toJson()],
      });

  /// 合并一份远端导出。返回实际发生变化的条目数。
  Future<int> mergeFromJson(String raw) async {
    final remote = decodeEntries(raw);
    if (remote.isEmpty) return 0;
    final local = {for (final entry in all()) entry.subjectId: entry};
    final merged = mergeResumeEntries(local, remote);
    var changed = 0;
    for (final entry in merged.values) {
      final old = local[entry.subjectId];
      if (old == null || old.updatedAt != entry.updatedAt ||
          old.positionSeconds != entry.positionSeconds) {
        await write(entry);
        changed++;
      }
    }
    return changed;
  }
}

/// 解析导出文件里的条目列表。
Map<int, ResumeEntry> decodeEntries(String raw) {
  try {
    final decoded = jsonDecode(raw);
    final list = switch (decoded) {
      {'entries': final List<dynamic> entries} => entries,
      final List<dynamic> entries => entries,
      _ => const <dynamic>[],
    };
    final result = <int, ResumeEntry>{};
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final entry = ResumeEntry.fromJson(item);
      if (entry != null) result[entry.subjectId] = entry;
    }
    return result;
  } catch (_) {
    return const {};
  }
}

/// 纯函数：合并两份记录。
///
/// 规则：
/// - 同一部番只有一边有 → 直接取那一边；
/// - 两边都有，按 [ResumeEntry.updatedAt] 取更新的一条；
/// - 更新时间相同且是同一集 → 取播放位置更靠后的（宁可多跳一点，不要退回去）。
Map<int, ResumeEntry> mergeResumeEntries(
  Map<int, ResumeEntry> local,
  Map<int, ResumeEntry> remote,
) {
  final merged = <int, ResumeEntry>{...local};
  for (final entry in remote.values) {
    final current = merged[entry.subjectId];
    if (current == null) {
      merged[entry.subjectId] = entry;
      continue;
    }
    final compare = entry.updatedAt.compareTo(current.updatedAt);
    if (compare > 0) {
      merged[entry.subjectId] = entry;
    } else if (compare == 0 &&
        entry.episodeId == current.episodeId &&
        entry.positionSeconds > current.positionSeconds) {
      merged[entry.subjectId] = entry;
    }
  }
  return merged;
}
