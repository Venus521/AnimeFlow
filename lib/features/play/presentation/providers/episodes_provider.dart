import 'package:anime_flow/features/play/domain/play_session_actions.dart';
import 'package:anime_flow/features/play/domain/episodes_data.dart';
import 'package:anime_flow/features/play/application/episode_selection.dart';
import 'package:anime_flow/features/play/application/resume_trace.dart';
import 'package:anime_flow/features/play/infrastructure/history/hive_resume_store.dart';
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

    ResumeTrace.instance.add(
      '①路由',
      'subject=$subjectId id=$requestedEpisodeId sort=$requestedEpisodeSort',
    );
    // 路由没带集数时（详情页大播放按钮、首页「继续观看」卡片等入口），
    // 回落到本地播放记录。不回落到这里的话，下面会一路退成
    // 「没指定剧集 → 默认第一集」，表现就是每次进来都从第一集开始。
    // 注意：记录卡、详情页、历史入口都会传 continueEpisodeId，
    // 所以「两个参数都为 null」这种判断等于永远不成立（上一版就死在这里）。
    // 这里改成无条件读一次记录，供下面两级兜底使用。
    final routeEpisodeId = requestedEpisodeId;
    final record =
        await ref.read(playHistoryServiceProvider).recordFor(subjectId);
    final own = resumeStore.read(subjectId);
    if (!ref.mounted) return EpisodesData(subjectId: subjectId);
    ResumeTrace.instance.add(
      '②记录',
      record == null
          ? '本地无记录'
          : 'id=${record.episodeId} sort=${record.episodeSort} '
              'pos=${record.position}s 源=${record.sourceWebsite ?? "未存"}',
    );
    if (own != null) {
      ResumeTrace.instance.add(
        '②自有',
        'id=${own.episodeId} sort=${own.episodeSort} '
            'pos=${own.positionSeconds}s 源=${own.website ?? "未记录"}',
      );
    }
    if (routeEpisodeId == null) {
      // 自有记录优先：它不参与作者服务器同步，不会被远端旧数据覆盖，
      // 也不会被「封面/时长为空」这类守卫丢掉。PlayHistory 只作后备。
      if (own != null && own.episodeId > 0) {
        requestedEpisodeId = own.episodeId;
        if (own.episodeSort > 0) requestedEpisodeSort = own.episodeSort;
      } else if (record != null) {
        if (record.episodeId > 0) requestedEpisodeId = record.episodeId;
        if (record.episodeSort > 0) requestedEpisodeSort = record.episodeSort;
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
    var data = selection.onlineEpisodes(
        subjectId, subjectEpisodes, requestedEpisodeId, _currentData,
        continueEpisodeSort: requestedEpisodeSort);

    // 一级兜底：路由给的集 ID 在剧集表里找不到（换过源、旧记录、剧集表变动），
    // 选集会退成「没有集」= episodeId 0，播放页随后自己退回第一集，
    // 于是把 1 写进记录 —— 这就是「永远显示 01、续播永远失效」的自我强化环。
    // 这里改用记录里的集数再定位一次，集数比集 ID 耐得住剧集表变动。
    final fallbackSort = own != null && own.episodeSort > 0
        ? own.episodeSort
        : (record != null && record.episodeSort > 0 ? record.episodeSort : 0);
    if (data.episodeId <= 0 && fallbackSort > 0) {
      final byRecordSort = selection.onlineEpisodes(
        subjectId,
        subjectEpisodes,
        null,
        null,
        continueEpisodeSort: fallbackSort,
      );
      if (byRecordSort.episodeId > 0) data = byRecordSort;
      ResumeTrace.instance.add(
        '③选集',
        '路由集 ID 没找到 → 按记录集数 $fallbackSort 重试 → '
            'id=${byRecordSort.episodeId}',
      );
    }

    // 二级兜底：仍然没有有效集，退回「下一集未看 / 第一集」，
    // 至少保证播放页拿得到一个真实存在的集，不会再写进 0 或空值。
    if (data.episodeId <= 0) {
      data = selection.onlineEpisodes(subjectId, subjectEpisodes, null, null);
      ResumeTrace.instance.add('③选集', '记录集数也对不上 → 退回下一集未看/第一集');
    }
    ResumeTrace.instance.add(
      '③选集',
      '最终 id=${data.episodeId} sort=${data.episodeSort} '
          'index=${data.episodeIndex}',
    );
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
