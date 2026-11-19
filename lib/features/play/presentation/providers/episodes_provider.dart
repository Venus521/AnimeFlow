import 'package:anime_flow/features/play/domain/play_session_actions.dart';
import 'package:anime_flow/features/play/domain/episodes_data.dart';
import 'package:anime_flow/features/play/application/episode_selection.dart';
import 'package:anime_flow/features/play/presentation/providers/play_dependencies.dart';
import 'package:anime_flow/features/play/presentation/providers/play_provider.dart';
import 'package:anime_flow/features/subject_episodes/application/subject_episodes_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
export '../../domain/episodes_data.dart';
part 'episodes_provider.g.dart';

@Riverpod(dependencies: [playExtra])
class Episodes extends _$Episodes implements EpisodeActions {
  final selection = PlayEpisodeSelection();
  EpisodesData? get _currentData => state.asData?.value;

  @override
  Future<EpisodesData> build() async {
    final extra = ref.watch(playExtraProvider);
    final subjectId = extra.playExtra.subjectId;
    var requestedEpisodeId = extra.continueEpisodeId;
    var requestedEpisodeSort = extra.continueEpisodeSort;
    if (extra.isOfflineMode) {
      return selection.offlineEpisodes(
          subjectId: subjectId,
          requestedEpisodeId: requestedEpisodeId,
          offlineEpisodeUrl: extra.offlineEpisodeUrl,
          availableEpisodes: [
            for (final episode in extra.offlineEpisodes)
              if (episode.localMediaPath.trim().isNotEmpty) episode,
          ]);
    }

    // 路由没带集数时（详情页大播放按钮、首页「继续观看」卡片等入口），
    // 回落到本地播放记录。不回落到这里的话，下面会一路退成
    // 「没指定剧集 → 默认第一集」，表现就是每次进来都从第一集开始。
    final hintFromRecord =
        requestedEpisodeId == null && requestedEpisodeSort == null;
    if (requestedEpisodeId == null || requestedEpisodeSort == null) {
      final routeEpisodeId = requestedEpisodeId;
      final record =
          await ref.read(playHistoryServiceProvider).recordFor(subjectId);
      if (!ref.mounted) return EpisodesData(subjectId: subjectId);
      if (record != null) {
        if (routeEpisodeId == null) {
          requestedEpisodeId = record.episodeId > 0 ? record.episodeId : null;
        }
        // 只有记录说的确实是同一集时，才借用它的集数。
        // 否则（用户点了别的集）会把进度带到错误的集上。
        final sameEpisode =
            routeEpisodeId == null || record.episodeId == routeEpisodeId;
        if (requestedEpisodeSort == null &&
            sameEpisode &&
            record.episodeSort > 0) {
          requestedEpisodeSort = record.episodeSort;
        }
      }
    }

    selection.request(subjectId, requestedEpisodeId);
    if (requestedEpisodeId != null) {
      await ref
          .read(subjectEpisodesProvider(subjectId).notifier)
          .loadUntilEpisodeId(requestedEpisodeId);
    }
    final subjectEpisodesAsync = ref.watch(subjectEpisodesProvider(subjectId));
    final subjectEpisodes = switch (subjectEpisodesAsync) {
      AsyncData(:final value) => value,
      AsyncError(:final error, :final stackTrace) =>
        Error.throwWithStackTrace(error, stackTrace),
      _ => await ref.watch(subjectEpisodesProvider(subjectId).future),
    };
    final data = selection.onlineEpisodes(
        subjectId, subjectEpisodes, requestedEpisodeId, _currentData,
        continueEpisodeSort: requestedEpisodeSort);
    // 记录里的集数对不上（条目剧集表变了、集数超出已加载范围）时，
    // 退回原来的「下一集未看」逻辑，至少不会停在空选集上。
    if (hintFromRecord && data.episodeId <= 0) {
      return selection.onlineEpisodes(subjectId, subjectEpisodes, null, null);
    }
    return data;
  }

  /// 通过条目剧集列表的统一入口更新观看状态，复用生命周期与会话保护。
  @override
  Future<void> updateEpisodeWatched(int episodeId,
      {bool watched = true}) async {
    if (!ref.mounted) return;
    final current = _currentData;
    if (current == null || current.subjectId <= 0) return;
    await ref
        .read(subjectEpisodesProvider(current.subjectId).notifier)
        .updateEpisodeWatched(episodeId: episodeId, watched: watched);
  }

  @override
  bool hasNextEpisode() => selection.hasNextEpisode(_currentData,
      offline: ref.read(playExtraProvider).isOfflineMode);

  void selectEpisode(int episodeId) {
    final next = selection.selectEpisode(_currentData, episodeId);
    if (!identical(next, _currentData)) state = AsyncData(next);
  }

  @override
  void switchToNextEpisode() {
    final next = selection.nextEpisode(_currentData,
        offline: ref.read(playExtraProvider).isOfflineMode);
    if (next != null) state = AsyncData(next);
  }
}
