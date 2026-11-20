import 'package:anime_flow/features/play/application/resume_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements ResumeStorage {
  final Map<String, String> data = {};

  @override
  String? readRaw(String key) => data[key];

  @override
  Future<void> writeRaw(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Iterable<String> keys() => data.keys.toList(growable: false);
}

ResumeEntry _entry({
  int subjectId = 1,
  int episodeId = 100,
  int sort = 1,
  int position = 60,
  String? website = 'site-a',
  DateTime? at,
}) =>
    ResumeEntry(
      subjectId: subjectId,
      episodeId: episodeId,
      episodeSort: sort,
      positionSeconds: position,
      durationSeconds: 1440,
      website: website,
      updatedAt: at ?? DateTime(2026, 11, 20, 12),
    );

void main() {
  group('ResumeEntry', () {
    test('编解码往返不丢字段', () {
      final source = _entry(position: 3725, website: 'site-b');
      final decoded = ResumeEntry.decode(source.encode())!;
      expect(decoded.subjectId, source.subjectId);
      expect(decoded.episodeId, source.episodeId);
      expect(decoded.episodeSort, source.episodeSort);
      expect(decoded.positionSeconds, 3725);
      expect(decoded.website, 'site-b');
      expect(decoded.updatedAt, source.updatedAt);
    });

    test('坏数据不抛异常，返回 null', () {
      expect(ResumeEntry.decode('not json'), isNull);
      expect(ResumeEntry.decode('{}'), isNull);
      expect(ResumeEntry.decode('{"subjectId":0,"episodeId":3}'), isNull);
    });

    test('集 ID 失效时按集数认定同一集', () {
      final entry = _entry(episodeId: 100, sort: 3);
      expect(entry.matches(episodeId: 100), isTrue);
      expect(entry.matches(episodeId: 999, episodeSort: 3), isTrue);
      expect(entry.matches(episodeId: 999, episodeSort: 4), isFalse);
      expect(entry.matches(episodeId: 999), isFalse);
    });
  });

  group('mergeResumeEntries', () {
    test('只有一边有时直接取那一边', () {
      final merged = mergeResumeEntries(
        {1: _entry(subjectId: 1)},
        {2: _entry(subjectId: 2)},
      );
      expect(merged.keys.toSet(), {1, 2});
    });

    test('同一部番取更新时间更新的一条', () {
      final older = _entry(position: 600, at: DateTime(2026, 11, 20, 10));
      final newer = _entry(position: 120, at: DateTime(2026, 11, 20, 11));
      final merged = mergeResumeEntries({1: older}, {1: newer});
      expect(merged[1]!.positionSeconds, 120);
    });

    test('更新时间相同时取播放更靠后的位置', () {
      final at = DateTime(2026, 11, 20, 11);
      final merged = mergeResumeEntries(
        {1: _entry(position: 300, at: at)},
        {1: _entry(position: 900, at: at)},
      );
      expect(merged[1]!.positionSeconds, 900);
    });

    test('更新时间相同但换了集，保留本地那条', () {
      final at = DateTime(2026, 11, 20, 11);
      final merged = mergeResumeEntries(
        {1: _entry(episodeId: 100, sort: 3, position: 300, at: at)},
        {1: _entry(episodeId: 200, sort: 5, position: 10, at: at)},
      );
      expect(merged[1]!.episodeId, 100);
    });
  });

  group('ResumeStore', () {
    test('写入后能读回，同一部番只留一条', () async {
      final store = ResumeStore(_MemoryStorage());
      await store.write(_entry(position: 60));
      await store.write(_entry(position: 120));
      expect(store.all().length, 1);
      expect(store.read(1)!.positionSeconds, 120);
    });

    test('mergeFromJson 只在数据变化时计入变更数', () async {
      final store = ResumeStore(_MemoryStorage());
      await store.write(_entry(position: 60, at: DateTime(2026, 11, 20, 10)));
      final remote = ResumeStore(_MemoryStorage());
      await remote.write(_entry(position: 300, at: DateTime(2026, 11, 20, 11)));
      expect(await store.mergeFromJson(remote.exportJson()), 1);
      expect(store.read(1)!.positionSeconds, 300);
      expect(await store.mergeFromJson(remote.exportJson()), 0);
    });

    test('clear 只清自己的键，不碰别的设置', () async {
      final storage = _MemoryStorage();
      storage.data['other_setting'] = 'keep-me';
      final store = ResumeStore(storage);
      await store.write(_entry());
      await store.clear();
      expect(store.all(), isEmpty);
      expect(storage.data['other_setting'], 'keep-me');
    });

    test('导出再导入另一台设备，进度能接上', () async {
      final phoneA = ResumeStore(_MemoryStorage());
      await phoneA.write(_entry(position: 300, website: 'site-a'));

      final phoneB = ResumeStore(_MemoryStorage());
      await phoneB.mergeFromJson(phoneA.exportJson());

      final resumed = phoneB.read(1)!;
      expect(resumed.positionSeconds, 300);
      expect(resumed.website, 'site-a');
    });
  });
}
