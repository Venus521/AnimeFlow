import 'package:anime_flow/features/play/application/episode_selection.dart';
import 'package:anime_flow/features/play/domain/episodes_data.dart';
import 'package:anime_flow/features/subject_episodes/domain/subject_episodes_state.dart';
import 'package:anime_flow/shared/models/player/bangumi/episodes_item.dart';
import 'package:test/test.dart';

const _subjectId = 42;

/// 造一份「第 1~8 集」的剧集表，id = 100 + 集数。
SubjectEpisodesState buildEpisodes({
  int count = 8,
  Set<int> watchedSorts = const {},
}) {
  final data = [
    for (var i = 1; i <= count; i++)
      EpisodeData(
        id: 100 + i,
        subjectID: _subjectId,
        sort: i.toDouble(),
        type: 0,
        disc: 0,
        name: '第$i话',
        nameCN: '第$i话',
        duration: '',
        airdate: '2020-01-01',
        comment: 0,
        desc: '',
        watched: watchedSorts.contains(i),
      ),
  ];
  return SubjectEpisodesState(
    episodes: EpisodesItem(data: data, total: data.length),
  );
}

EpisodesData resolve({
  required SubjectEpisodesState episodes,
  int? continueEpisodeId,
  int? continueEpisodeSort,
  EpisodesData? current,
}) {
  return PlayEpisodeSelection().onlineEpisodes(
    _subjectId,
    episodes,
    continueEpisodeId,
    current,
    continueEpisodeSort: continueEpisodeSort,
  );
}

void main() {
  group('按集数定位（集 ID 失效时的兜底）', () {
    test('findSelectionBySort 能按集数找到对应剧集', () {
      final selection = buildEpisodes().findSelectionBySort(5);
      expect(selection, isNotNull);
      expect(selection!.id, 105);
      expect(selection.index, 5);
      expect(selection.sort, 5.0);
    });

    test('集 ID 失效但集数有效时，定位到正确的那一集', () {
      final data = resolve(
        episodes: buildEpisodes(),
        continueEpisodeId: 999999,
        continueEpisodeSort: 5,
      );
      expect(data.episodeIndex, 5);
      expect(data.episodeId, 105);
      expect(data.episodeSort, 5.0);
    });
  });

  group('没带集数时的默认行为', () {
    test('完全没有提示时退回第一集（历史行为，需由调用方补记录兜底）', () {
      final data = resolve(episodes: buildEpisodes());
      expect(data.episodeIndex, 1);
      expect(data.episodeId, 101);
    });

    test('有已看标记时退回「下一集未看」', () {
      final data = resolve(
        episodes: buildEpisodes(watchedSorts: {1, 2, 3}),
      );
      expect(data.episodeIndex, 4);
      expect(data.episodeId, 104);
    });

    test('集数为 0 的记录不参与定位，不能误判成第一集之外的集', () {
      final data = resolve(
        episodes: buildEpisodes(),
        continueEpisodeSort: 0,
      );
      // 0 被当成「没有提示」，走默认逻辑，而不是去匹配 sort=0 的剧集。
      expect(data.episodeIndex, 1);
    });
  });

  group('提示的优先级', () {
    test('集 ID 有效时优先按 ID，不被集数带偏', () {
      final data = resolve(
        episodes: buildEpisodes(),
        continueEpisodeId: 107,
        continueEpisodeSort: 2,
      );
      expect(data.episodeIndex, 7);
      expect(data.episodeId, 107);
    });

    test('当前已有选中集时保持不动，不会被历史记录拉回旧集', () {
      final current = EpisodesData(
        subjectId: _subjectId,
        episodeIndex: 3,
        episodeId: 103,
        episodeSort: 3,
      );
      final data = resolve(
        episodes: buildEpisodes(),
        continueEpisodeId: 106,
        continueEpisodeSort: 6,
        current: current,
      );
      expect(data.episodeIndex, 3);
      expect(data.episodeId, 103);
    });

    test('提示的集数超出剧集表时不猜测，返回空选集交给调用方兜底', () {
      final data = resolve(
        episodes: buildEpisodes(count: 3),
        continueEpisodeId: 999999,
        continueEpisodeSort: 5,
      );
      expect(data.episodeId, 0);
      expect(data.episodeIndex, 0);
    });
  });
}
