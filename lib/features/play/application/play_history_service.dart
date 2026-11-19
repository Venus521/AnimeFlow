import 'package:anime_flow/core/async/serial_operation_queue.dart';
import 'package:anime_flow/features/play/domain/play_history_repository.dart';

class PlayHistoryService {
  PlayHistoryService(this.repository);
  final PlayHistoryRepository repository;

  final _queue = SerialOperationQueue(ensureReady: () {});
  Future<void>? _synchronizing;
  Future<PlayHistorySyncResult> syncPending() =>
      _queue.run(repository.syncPending);
  Future<void> clearLocal() => _queue.run(repository.clearLocal);
  Future<List<PlaybackRecord>> records() async => (await repository.getAll())
    ..sort((a, b) => b.updateAt.compareTo(a.updateAt));
  Stream<void> get changes => repository.changes;

  /// 该条目的本地播放记录，没有则返回 null。
  ///
  /// 播放页在路由没有指定集数时用它决定「从第几集开始」，
  /// 避免退化成每次都从第一集播。
  Future<PlaybackRecord?> recordFor(int subjectId) =>
      repository.getBySubjectId(subjectId);

  Future<int> resumePosition(
    int subjectId,
    int episodeId, {
    num? episodeSort,
  }) async {
    final record = await repository.getBySubjectId(subjectId);
    if (record == null) return 0;
    // 集 ID 失效时按集数兜底，避免「明明看过第 N 集却从第一集开始」。
    // 集数为 0 的记录不可信（旧数据/本地文件），不能拿来比对，
    // 否则会误判成同一集，把别的集进度套过来。
    final sameEpisode = record.episodeId == episodeId ||
        (episodeSort != null &&
            episodeSort > 0 &&
            record.episodeSort == episodeSort);
    return sameEpisode && record.position > 0 ? record.position : 0;
  }

  /// 上次播放这一集使用的数据源名称。
  ///
  /// 只在该记录确实属于这一集时返回，避免把别的集的站点套过来。
  Future<String?> resumeSource(
    int subjectId,
    int episodeId, {
    num? episodeSort,
  }) async {
    final record = await repository.getBySubjectId(subjectId);
    if (record == null) return null;
    final sameEpisode = record.episodeId == episodeId ||
        (episodeSort != null &&
            episodeSort > 0 &&
            record.episodeSort == episodeSort);
    if (!sameEpisode) return null;
    final website = record.sourceWebsite?.trim() ?? '';
    return website.isEmpty ? null : website;
  }

  Future<void> synchronize({required bool Function() active}) =>
      _synchronizing ??= _queue
          .run(() => _synchronize(active))
          .whenComplete(() => _synchronizing = null);

  Future<void> _synchronize(bool Function() active) async {
    for (var attempt = 1; attempt <= 3 && active(); attempt++) {
      try {
        await repository.syncPending();
        if (active()) await repository.syncFromServer();
        return;
      } catch (_) {
        if (!active()) return;
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
  }
}
