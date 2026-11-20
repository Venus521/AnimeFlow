import 'package:anime_flow/core/logger/app_log.dart';
import 'dart:async';

import 'package:anime_flow/features/play/application/resume_trace.dart';
import 'package:anime_flow/features/play/infrastructure/sync/webdav_sync.dart';
import 'package:anime_flow/features/play/presentation/providers/play_history_provider.dart';
import 'package:anime_flow/shared/navigation/app_navigator_provider.dart';
import 'package:anime_flow/shared/navigation/args/info_route_extra.dart';
import 'package:anime_flow/shared/navigation/args/play_route_extra.dart';
import 'package:anime_flow/core/utils/format_time_util.dart';
import 'package:anime_flow/core/utils/playback_format.dart';
import 'package:anime_flow/shared/widgets/animation_network_image.dart';
import 'package:anime_flow/shared/widgets/notification_toast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anime_flow/app/localization/app_localizations.dart';

class PlayRecordPage extends ConsumerStatefulWidget {
  const PlayRecordPage({super.key});

  @override
  ConsumerState<PlayRecordPage> createState() => _PlayRecordPageState();
}

class _PlayRecordPageState extends ConsumerState<PlayRecordPage> {
  bool _isSyncing = false;
  bool _isClearing = false;

  int _calculateCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    const minItemWidth = 320.0;
    if (width < 450) return 1;
    return (width / minItemWidth).floor().clamp(1, 4);
  }

  Future<void> _syncPendingRecords() async {
    if (_isSyncing) return;
    setState(() {
      _isSyncing = true;
    });

    try {
      final result = await ref.read(playHistoryProvider.notifier).syncPending();
      if (!mounted) return;

      final l10n = AppLocalizations.of(context);
      final message = result.requiresLogin
          ? l10n.loginToManageAccount
          : result.failed > 0
              ? l10n.syncStatusFailed
              : result.total == 0
                  ? l10n.syncStatusSuccess
                  : l10n.syncedItems(result.synced);
      NotificationToast.show(message, title: '提示');
    } catch (e) {
      logError('手动同步播放记录失败: $e');
      if (mounted) {
        NotificationToast.show(AppLocalizations.of(context).syncStatusFailed,
            title: '提示');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _confirmAndSyncPendingRecords() async {
    if (_isSyncing) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.confirm),
        content: const Text('是否将未同步的播放记录同步到服务器？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _syncPendingRecords();
    }
  }

  Future<void> _clearLocalRecords() async {
    if (_isClearing) return;
    setState(() {
      _isClearing = true;
    });

    try {
      await ref.read(playHistoryProvider.notifier).clearLocal();
      if (mounted) {
        NotificationToast.show(AppLocalizations.of(context).deleteSuccess,
            title: '提示');
      }
    } catch (e) {
      logError('清理本地播放记录失败: $e');
      if (mounted) {
        NotificationToast.show(AppLocalizations.of(context).deleteFailed,
            title: '提示');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isClearing = false;
        });
      }
    }
  }

  Future<void> _confirmAndClearLocalRecords() async {
    if (_isClearing) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.confirm),
        content: const Text('是否清空本地播放记录？云端播放记录不会被删除，可稍后重新从云端同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _clearLocalRecords();
    }
  }

  /// 把续播链路的运行时记录摊开给人看：路由传了什么、选到第几集、
  /// 写进记录什么、读回来什么。不联网、不上传，只在本机内存里。
  Future<void> _showResumeTrace() async {
    final text = ResumeTrace.instance.dump();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('续播诊断'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.of(dialogContext).pop();
              NotificationToast.show('已复制，直接粘贴发给我', title: '提示');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () {
              ResumeTrace.instance.clear();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // 打开记录页时自动从自己的 WebDAV 合并一次；没配置就安静跳过。
    if (WebDavConfig.load().isConfigured) {
      unawaited(WebDavSync.instance.pull());
    }
  }

  /// 配置并手动同步自己的 WebDAV。
  ///
  /// 只放一个几 KB 的 JSON，不涉及任何第三方账号，也不需要服务器。
  Future<void> _openWebDavDialog() async {
    final config = WebDavConfig.load();
    final urlController = TextEditingController(text: config.url);
    final userController = TextEditingController(text: config.username);
    final passController = TextEditingController(text: config.password);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('WebDAV 同步'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '目录地址',
                  hintText: 'https://dav.jianguoyun.com/dav/AnimeFlow',
                ),
              ),
              TextField(
                controller: userController,
                decoration: const InputDecoration(labelText: '账号'),
              ),
              TextField(
                controller: passController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '应用密码'),
              ),
              const SizedBox(height: 14),
              const Text(
                '只存一个几 KB 的进度 JSON，不放视频、不放账号信息。'
                '目录需要先在网盘里建好。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await WebDavConfig(
                url: urlController.text,
                username: userController.text,
                password: passController.text,
              ).save();
              final result = await WebDavSync.instance.push();
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              NotificationToast.show(
                result.message,
                title: result.ok ? '已保存并上传' : '上传失败',
              );
            },
            child: const Text('保存并上传'),
          ),
          TextButton(
            onPressed: () async {
              final result = await WebDavSync.instance.pull();
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              NotificationToast.show(
                result.message,
                title: result.ok ? '已从远端恢复' : '恢复失败',
              );
            },
            child: const Text('从远端恢复'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.listen(playHistoryProvider, (previous, next) {
      final error = next.value?.syncError;
      if (error == null || previous?.value?.syncError == error) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      NotificationToast.show(l10n.syncStatusFailed, title: l10n.tip);
    });
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.playbackHistory),
        actions: [
          IconButton(
            tooltip: 'WebDAV 同步',
            onPressed: _openWebDavDialog,
            icon: const Icon(Icons.cloud_outlined),
          ),
          IconButton(
            tooltip: '续播诊断',
            onPressed: _showResumeTrace,
            icon: const Icon(Icons.bug_report_outlined),
          ),
          IconButton(
            tooltip: _isSyncing ? l10n.syncInProgress : l10n.manualSync,
            onPressed: _isSyncing ? null : _confirmAndSyncPendingRecords,
            icon: _isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined),
          ),
          IconButton(
            tooltip: l10n.delete,
            onPressed: _isClearing ? null : _confirmAndClearLocalRecords,
            icon: _isClearing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Center(
        child: Consumer(
          builder: (context, ref, child) {
            final playHistoryAsync = ref.watch(playHistoryProvider);
            final playHistoryList = playHistoryAsync.value?.records;
            if (playHistoryAsync.isLoading && playHistoryList == null) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            } else if (playHistoryList == null || playHistoryList.isEmpty) {
              return Center(
                child: Text(l10n.noData),
              );
            } else {
              return ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1800),
                child: GridView.builder(
                  padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: MediaQuery.of(context).padding.bottom),
                  itemCount: playHistoryList.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _calculateCrossAxisCount(context),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 2.5,
                  ),
                  itemBuilder: (context, index) {
                    final playHistory = playHistoryList[index];
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => appNavigatorOf(context)
                          .openAnimeInfoFromExtra<void>(InfoRouteExtra(
                              id: playHistory.subjectId,
                              name: playHistory.subjectName,
                              image: playHistory.cover)),
                      child: Row(
                        children: [
                          AspectRatio(
                            aspectRatio: 2 / 3,
                            child: AnimationNetworkImage(
                              filterQuality: FilterQuality.high,
                              borderRadius: BorderRadius.circular(8),
                              fit: BoxFit.cover,
                              url: playHistory.cover,
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    playHistory.subjectName,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  Row(
                                    children: [
                                      Text(
                                          FormatTimeUtil.formatDateTime(
                                              playHistory.updateAt),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold)),
                                      Text(
                                        l10n.watchedLabel(
                                          calculatePercentage(
                                            playHistory.position,
                                            playHistory.duration,
                                          ),
                                        ),
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(
                                        playHistory.isSyncedToServer
                                            ? Icons.cloud_done_outlined
                                            : Icons.cloud_upload_outlined,
                                        size: 16,
                                        color: playHistory.isSyncedToServer
                                            ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        playHistory.isSyncedToServer
                                            ? l10n.syncStatusSuccess
                                            : l10n.syncStatusIdle,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: playHistory.isSyncedToServer
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Expanded(
                                      child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      const Spacer(),
                                      ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                              elevation: 0),
                                          onPressed: () async {
                                            await appNavigatorOf(context)
                                                .openPlay<void>(PlayRouteExtra(
                                                    playExtra: PlayExtra(
                                                      subjectId:
                                                          playHistory.subjectId,
                                                      subjectName: playHistory
                                                          .subjectName,
                                                      subjectCover:
                                                          playHistory.cover,
                                                      subjectAliases:
                                                          playHistory.alias,
                                                    ),
                                                    continueEpisodeId:
                                                        playHistory.episodeId,
                                                    continueEpisodeSort:
                                                        playHistory
                                                            .episodeSort));
                                          },
                                          child: Text(
                                            l10n.playEpisode(
                                              playHistory.episodeSort
                                                  .toString()
                                                  .padLeft(2, '0'),
                                            ),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold),
                                          ))
                                    ],
                                  ))
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            }
          },
        ),
      ),
    );
  }
}
