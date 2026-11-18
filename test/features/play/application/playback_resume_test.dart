import 'package:anime_flow/features/play/application/play_history_service.dart';
import 'package:anime_flow/features/play/application/playback_progress_manager.dart';
import 'package:anime_flow/features/play/domain/play_history_repository.dart';
import 'package:anime_flow/shared/models/player/play/play_history_event_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存版播放记录仓储，避免测试依赖 Hive。
class _FakeHistory implements PlayHistoryRepository {
  final Map<int, PlaybackRecord> records = {};

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<PlaybackRecord>> getAll() async => records.values.toList();

  @override
  Future<PlaybackRecord?> getBySubjectId(int subjectId) async =>
      records[subjectId];

  @override
  Future<void> save(
    PlaybackRecord record, {
    required PlayHistoryEventType eventType,
  }) async {
    records[record.subjectId] = record;
  }

  @override
  Future<void> clearPosition(int subjectId) async {
    final record = records[subjectId];
    if (record == null) return;
    records[subjectId] = PlaybackRecord(
      subjectId: record.subjectId,
      episodeId: record.episodeId,
      episodeSort: record.episodeSort,
      subjectName: record.subjectName,
      cover: record.cover,
      updateAt: record.updateAt,
      position: 0,
      duration: 0,
      alias: record.alias,
      sourceWebsite: record.sourceWebsite,
    );
  }

  @override
  Future<PlayHistorySyncResult> syncPending() async =>
      const PlayHistorySyncResult();

  @override
  Future<PlayHistoryPullResult> syncFromServer() async =>
      const PlayHistoryPullResult();

  @override
  Future<void> clearLocal() async => records.clear();
}

PlaybackProgressManager _manager(_FakeHistory history) {
  return PlaybackProgressManager(
    history: history,
    autoMarkEnabled: () => false,
    onEpisodeWatched: ({
      required int subjectId,
      required int episodeId,
      required bool watched,
    }) {},
    markEpisodeWatched: (episodeId) async {},
  );
}

void _use(
  PlaybackProgressManager manager, {
  int episodeId = 10,
  int episodeSort = 1,
  String? subjectCover = 'https://example.com/cover.jpg',
  String? sourceWebsite = '站A',
}) {
  manager.setPlaybackContext(
    subjectId: 1,
    episodeId: episodeId,
    episodeSort: episodeSort,
    subjectName: '葬送的芙莉莲',
    subjectCover: subjectCover,
    alias: const [],
    isLocalPlayback: false,
    sourceWebsite: sourceWebsite,
  );
}

void main() {
  group('续播：记住上次的数据源', () {
    test('保存记录时写入数据源名称', () async {
      final history = _FakeHistory();
      final manager = _manager(history);
      _use(manager, sourceWebsite: '站A');

      manager.updatePlaybackState(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();

      expect(history.records[1]?.sourceWebsite, '站A');
      expect(history.records[1]?.position, 600);
    });

    test('resumeSource 只在该记录属于同一集时返回站点', () async {
      final history = _FakeHistory();
      final manager = _manager(history);
      final service = PlayHistoryService(history);

      _use(manager, episodeId: 10, sourceWebsite: '站A');
      manager.updatePlaybackState(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();

      expect(await service.resumeSource(1, 10), '站A');
      // 换一集就不该套用上一集的站点
      expect(await service.resumeSource(1, 11), isNull);
    });

    test('旧记录没有站点字段时返回 null 而不是空串', () async {
      final history = _FakeHistory();
      final manager = _manager(history);
      final service = PlayHistoryService(history);

      _use(manager, sourceWebsite: null);
      manager.updatePlaybackState(
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();

      expect(await service.resumeSource(1, 10), isNull);
      // 但进度本身照常可用
      expect(await service.resumePosition(1, 10), 300);
    });
  });

  group('续播：不再丢进度', () {
    test('切换剧集时重置上一集的位置与时长', () async {
      final history = _FakeHistory();
      final manager = _manager(history);

      _use(manager, episodeId: 10, episodeSort: 1);
      manager.updatePlaybackState(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );

      _use(manager, episodeId: 11, episodeSort: 2);

      expect(manager.position, Duration.zero);
      expect(manager.duration, Duration.zero);
    });

    test('播放器尚未回报位置时，不会把已有进度覆盖成 0', () async {
      final history = _FakeHistory();
      final manager = _manager(history);

      // 第一集看到 10 分钟
      _use(manager, episodeId: 10, episodeSort: 1);
      manager.updatePlaybackState(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();
      expect(history.records[1]?.position, 600);

      // 重新打开同一集：时长已回报、位置还没回报
      _use(manager, episodeId: 10, episodeSort: 1);
      manager.updatePlaybackState(
        position: Duration.zero,
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();

      // 进度必须还是 600，不能被抹成 0
      expect(history.records[1]?.position, 600);
    });

    test('用户显式拖到 0 时仍然允许写入', () async {
      final history = _FakeHistory();
      final manager = _manager(history);

      _use(manager, episodeId: 10, episodeSort: 1);
      manager.updatePlaybackState(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();

      await manager.save(
        position: Duration.zero,
        eventType: PlayHistoryEventType.forceOverwrite,
      );

      expect(history.records[1]?.position, 0);
    });

    test('封面缺失时仍然保存记录', () async {
      final history = _FakeHistory();
      final manager = _manager(history);

      _use(manager, subjectCover: null);
      manager.updatePlaybackState(
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 24),
        playing: true,
        isLoggedIn: false,
      );
      await manager.save();

      expect(history.records[1], isNotNull);
      expect(history.records[1]?.cover, '');
      expect(history.records[1]?.position, 180);
    });
  });
}
