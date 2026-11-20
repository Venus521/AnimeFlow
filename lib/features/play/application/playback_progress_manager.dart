import 'package:anime_flow/features/play/domain/play_history_repository.dart';
import 'dart:async';

import 'package:anime_flow/core/logger/app_log.dart';
import 'package:anime_flow/features/play/application/resume_store.dart';
import 'package:anime_flow/features/play/application/resume_trace.dart';
import 'package:anime_flow/features/play/infrastructure/history/hive_resume_store.dart';
import 'package:anime_flow/features/play/infrastructure/sync/webdav_sync.dart';
import 'package:anime_flow/shared/models/player/play/play_history_event_type.dart';

typedef SetEpisodeWatchedCallback = void Function({
  required int subjectId,
  required int episodeId,
  required bool watched,
});

typedef MarkEpisodeWatched = Future<void> Function(int episodeId);

/// 播放进度采集器与播放记录写入协调器。
class PlaybackProgressManager {
  PlaybackProgressManager({
    required this.onEpisodeWatched,
    required MarkEpisodeWatched markEpisodeWatched,
    required this.history,
    required this.autoMarkEnabled,
  }) : _markEpisodeWatched = markEpisodeWatched;

  static const watchedProgressThreshold = 0.90;
  static const saveDebounce = Duration(seconds: 3);

  /// 短于该时长的视频不参与「自动标记已看」。
  ///
  /// 预告、花絮、切片常常只有几十秒，播到 90% 并不代表这一集看过。
  static const Duration minDurationForAutoWatched = Duration(minutes: 2);

  final SetEpisodeWatchedCallback onEpisodeWatched;
  final MarkEpisodeWatched _markEpisodeWatched;
  final PlayHistoryRepository history;
  final bool Function() autoMarkEnabled;
  Future<void> _saveQueue = Future<void>.value();
  final Set<int> _autoWatchedEpisodeIds = {};
  final Set<int> _autoWatchedEpisodeUpdatesInFlight = {};
  Timer? _saveTimer;
  Duration? _pendingSeekPosition;

  int subjectId = 0;
  int episodeId = 0;
  int episodeSort = 0;
  String? subjectName;
  String? subjectCover;
  List<String> alias = [];

  /// 当前播放使用的数据源名称，随播放记录一起落盘。
  String? sourceWebsite;
  bool isLocalPlayback = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  void setPlaybackContext({
    required int subjectId,
    required int episodeId,
    required int episodeSort,
    required String? subjectName,
    required String? subjectCover,
    required List<String> alias,
    required bool isLocalPlayback,
    String? sourceWebsite,
  }) {
    this.subjectId = subjectId;
    this.episodeId = episodeId;
    this.episodeSort = episodeSort;
    this.subjectName = subjectName;
    this.subjectCover = subjectCover;
    this.alias = List<String>.from(alias);
    this.isLocalPlayback = isLocalPlayback;
    this.sourceWebsite = sourceWebsite;
    // 换集时必须清空上一集的位置与时长。
    // 否则播放器还没回报新位置时，防抖保存会拿上一集的数值写一条脏记录。
    position = Duration.zero;
    duration = Duration.zero;
  }

  void updatePlaybackState({
    required Duration position,
    required Duration duration,
    required bool playing,
    required bool isLoggedIn,
  }) {
    this.position = position;
    this.duration = duration;
    if (!isLoggedIn) return;
    if (!playing || duration <= Duration.zero) return;
    if (duration < minDurationForAutoWatched) return;
    if (isLocalPlayback || subjectId <= 0 || episodeId <= 0) return;
    if (subjectName == null || subjectCover == null) return;
    if (!autoMarkEnabled()) {
      return;
    }

    final progress = position.inMilliseconds / duration.inMilliseconds;
    if (progress < watchedProgressThreshold ||
        _autoWatchedEpisodeIds.contains(episodeId) ||
        _autoWatchedEpisodeUpdatesInFlight.contains(episodeId)) {
      return;
    }

    _autoWatchedEpisodeUpdatesInFlight.add(episodeId);
    unawaited(_autoUpdateEpisodeWatched(episodeId));
  }

  /// 合并暂停和开始播放产生的连续保存事件。
  void saveAfterPlaybackChange() {
    _scheduleSave();
  }

  /// 拖动期间只保留最后一个位置，停止拖动一小段时间后再提交。
  void saveAfterSeek(Duration position) {
    _pendingSeekPosition = position;
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, () {
      _saveTimer = null;
      final pendingPosition = _takePendingSeekPosition();
      unawaited(save(
        position: pendingPosition,
        eventType: pendingPosition == null
            ? PlayHistoryEventType.defaults
            : PlayHistoryEventType.forceOverwrite,
      ));
    });
  }

  Future<void> save({
    Duration? position,
    PlayHistoryEventType eventType = PlayHistoryEventType.defaults,
  }) async {
    final pendingSeekPosition = _takePendingSeekPosition();
    if (duration <= Duration.zero ||
        subjectId <= 0 ||
        episodeId <= 0 ||
        subjectName == null) {
      ResumeTrace.instance.add(
        '⑤落盘',
        '被守卫拦下 subject=$subjectId id=$episodeId '
            'dur=${duration.inSeconds}s name=${subjectName ?? "null"}',
      );
      return;
    }
    final savedPosition = position ?? pendingSeekPosition ?? this.position;
    final effectiveEventType = pendingSeekPosition != null &&
            eventType == PlayHistoryEventType.defaults
        ? PlayHistoryEventType.forceOverwrite
        : eventType;
    // 位置仍为 0 通常说明播放器还没回报位置（刚打开、刚换集）。
    // 这时落盘会把已有的续播进度抹成 0，所以直接跳过；
    // 用户显式拖到 0 会走 forceOverwrite，不受此限。
    if (savedPosition <= Duration.zero &&
        effectiveEventType != PlayHistoryEventType.forceOverwrite) {
      return;
    }
    ResumeTrace.instance.add(
      '⑤落盘',
      'id=$episodeId sort=$episodeSort pos=${savedPosition.inSeconds}s '
          'dur=${duration.inSeconds}s 源=${sourceWebsite ?? "未记录"}',
    );
    // 同时写一份「自有」记录：不参与作者服务器同步，不会被远端覆盖，
    // 也不会被上面那条守卫丢弃。续播读的是这一份。
    unawaited(
      resumeStore.write(
        ResumeEntry(
          subjectId: subjectId,
          episodeId: episodeId,
          episodeSort: episodeSort,
          positionSeconds: savedPosition.inSeconds,
          durationSeconds: duration.inSeconds,
          website: sourceWebsite,
          updatedAt: DateTime.now(),
        ),
      ),
    );
    if (WebDavConfig.load().isConfigured) {
      unawaited(WebDavSync.instance.pushThrottled());
    }
    final playHistory = PlaybackRecord(
      subjectId: subjectId,
      subjectName: subjectName!,
      episodeId: episodeId,
      episodeSort: episodeSort,
      // 封面缺失时用空串占位，不再整条丢弃（丢一条等于丢一次续播）。
      cover: subjectCover ?? '',
      updateAt: DateTime.now(),
      position: savedPosition.inSeconds,
      duration: duration.inSeconds,
      alias: List<String>.from(alias),
      sourceWebsite: sourceWebsite,
    );
    _saveQueue = _saveQueue.then((_) async {
      try {
        await history.save(
          playHistory,
          eventType: effectiveEventType,
        );
      } catch (e) {
        logError('保存播放进度失败: $e');
      }
    });
    await _saveQueue;
  }

  Duration? _takePendingSeekPosition() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final position = _pendingSeekPosition;
    _pendingSeekPosition = null;
    return position;
  }

  Future<void> _autoUpdateEpisodeWatched(int targetEpisodeId) async {
    try {
      await _markEpisodeWatched(targetEpisodeId);
      _autoWatchedEpisodeIds.add(targetEpisodeId);
      onEpisodeWatched(
        subjectId: subjectId,
        episodeId: targetEpisodeId,
        watched: true,
      );
    } catch (e) {
      logError('自动更新观看进度失败: $e');
    } finally {
      _autoWatchedEpisodeUpdatesInFlight.remove(targetEpisodeId);
    }
  }
}
