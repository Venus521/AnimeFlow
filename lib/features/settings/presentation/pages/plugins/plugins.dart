import 'package:anime_flow/shared/widgets/adaptive_app_bar.dart';
import 'package:anime_flow/features/settings/presentation/widgets/settings_page_builder.dart';
import 'package:anime_flow/shared/navigation/settings_destination.dart';
import 'dart:convert';
import 'dart:math' as math;

import 'package:anime_flow/core/crawler/item/crawler_config_item.dart';
import 'package:anime_flow/core/crawler/rule_api_level.dart';

import 'package:anime_flow/features/settings/presentation/providers/setting_provider.dart';
import 'package:anime_flow/features/source/application/providers/plugin_provider.dart';
import 'package:anime_flow/features/source/application/providers/source_configs_provider.dart';
import 'package:anime_flow/shared/navigation/app_navigator_provider.dart';
import 'package:anime_flow/features/source/data/repositories/source_repository.dart';
import 'package:anime_flow/features/settings/presentation/pages/plugins/plugin_install_message.dart';
import 'package:anime_flow/features/source/application/providers/source_repository_provider.dart';
import 'package:anime_flow/core/utils/utils.dart';
import 'package:anime_flow/core/logger/logger.dart';
import 'package:anime_flow/shared/widgets/animation_network_image.dart';
import 'package:anime_flow/shared/widgets/notification_toast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anime_flow/app/localization/app_localizations.dart';

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key});

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  late final SourceRepository _sourceRepository;
  final Set<String> _busyPluginNames = {};

  /// 串行化排序写入。
  Future<void> _orderWriteChain = Future<void>.value();

  bool _showSearch = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _sourceRepository = ref.read(sourceRepositoryProvider);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 批量导入：剪切板里可以是一个插件对象、一个数组，或 {"plugins": [...]}。
  ///
  /// 之所以做成批量，是因为公开规则库一次就是十几条，
  /// 一条条粘会把「导入源」变成一件劝退的事。
  Future<void> _importBatch() async {
    final l10n = AppLocalizations.of(context);
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final controller = TextEditingController(text: clipboard?.text ?? '');
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量导入源'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, maxWidth: 460),
          child: TextField(
            controller: controller,
            minLines: 8,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
              hintText: '粘贴一个 JSON 数组，或 {"plugins": [ ... ]}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || input.trim().isEmpty || !mounted) return;

    final List<dynamic> rawItems;
    try {
      final decoded = jsonDecode(input);
      rawItems = switch (decoded) {
        List<dynamic> value => value,
        {'plugins': final List<dynamic> value} => value,
        Map<String, dynamic> value => [value],
        _ => throw const FormatException('需要一个对象或数组'),
      };
    } catch (e) {
      NotificationToast.show('JSON 解析失败：$e', title: '导入失败');
      return;
    }

    var imported = 0;
    var overwritten = 0;
    final failures = <String>[];
    final existing = (await _sourceRepository.getSources())
        .map((source) => source.name)
        .toSet();

    for (final item in rawItems) {
      if (item is! Map) {
        failures.add('有一项不是对象');
        continue;
      }
      try {
        final config = CrawlConfigItem.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (config.name.trim().isEmpty) {
          failures.add('缺少 name');
          continue;
        }
        if (!config.isRuleCompatible) {
          failures.add('${config.name}：${RuleApiLevel.describe(config.api, ruleName: config.name)}');
          continue;
        }
        final isUpdate = existing.contains(config.name);
        await _sourceRepository.saveSource(config);
        if (isUpdate) {
          overwritten++;
        } else {
          imported++;
          existing.add(config.name);
        }
      } catch (e) {
        failures.add('${item['name'] ?? '未命名'}：$e');
      }
    }

    if (!mounted) return;
    ref.invalidate(sourceConfigsProvider);
    final parts = <String>[
      if (imported > 0) '新增 $imported',
      if (overwritten > 0) '覆盖 $overwritten',
      if (failures.isNotEmpty) '失败 ${failures.length}',
    ];
    NotificationToast.show(
      [
        parts.isEmpty ? '没有可导入的源' : parts.join(' · '),
        if (failures.isNotEmpty) failures.take(3).join('；'),
      ].join('\n'),
      title: '批量导入完成',
    );
  }

  /// 一键更新：把仓库里版本更高的源全部拉一遍。
  Future<void> _updateAll() async {
    final l10n = AppLocalizations.of(context);
    final remote =
        ref.read(pluginCatalogProvider).whenOrNull(data: (list) => list) ??
            const <PluginCatalogItem>[];
    if (remote.isEmpty) {
      NotificationToast.show('仓库还没拉到，检查网络或源仓库地址', title: '无法更新');
      return;
    }
    final locals = await _sourceRepository.getSources();
    final localByName = {for (final source in locals) source.name: source};
    final pending = [
      for (final plugin in remote)
        if (localByName[plugin.name] == null ||
            Utils.compareVersionNumbers(
                  plugin.version,
                  localByName[plugin.name]!.version,
                ) >
                0)
          plugin,
    ];
    if (!mounted) return;
    if (pending.isEmpty) {
      NotificationToast.show('全部已是最新版本', title: '无需更新');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('一键更新'),
        content: Text(
          '将更新 ${pending.length} 个源：\n'
          '${pending.take(6).map((plugin) => plugin.name).join('、')}'
          '${pending.length > 6 ? ' 等' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    var ok = 0;
    final failed = <String>[];
    for (final plugin in pending) {
      setState(() => _busyPluginNames.add(plugin.name));
      try {
        await _sourceRepository.updatePlugin(
          pluginPath: plugin.path,
          catalogVersion: plugin.version,
        );
        ok++;
      } catch (e) {
        failed.add(plugin.name);
        LiggLogger().e('Plugins: 批量更新 ${plugin.name} 失败', error: e);
      } finally {
        if (mounted) setState(() => _busyPluginNames.remove(plugin.name));
      }
    }
    if (!mounted) return;
    ref.invalidate(sourceConfigsProvider);
    NotificationToast.show(
      failed.isEmpty ? '成功 $ok 个' : '成功 $ok 个，失败 ${failed.length} 个：${failed.take(3).join('、')}',
      title: '一键更新完成',
    );
  }

  Future<void> deleteDataSource(String name) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.confirmDelete),
        content: Text(l10n.deleteSourceConfirmation(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _sourceRepository.deleteSource(name);
      if (!mounted) return;
      NotificationToast.show(l10n.sourceDeleted(name),
          title: l10n.deleteSuccess);
    } catch (e) {
      NotificationToast.show(
        l10n.sourceDeleteFailed(name, e.toString()),
        title: l10n.deleteFailed,
      );
    }
  }

  Future<void> _updatePlugin(PluginCatalogItem plugin) async {
    if (_busyPluginNames.contains(plugin.name)) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busyPluginNames.add(plugin.name);
    });
    try {
      await _sourceRepository.updatePlugin(
        pluginPath: plugin.path,
        catalogVersion: plugin.version,
      );
      if (!mounted) return;
      NotificationToast.show(
        l10n.pluginUpdated(plugin.name, plugin.version),
        title: l10n.updateSuccess,
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      LiggLogger().e(
        'Plugins: 更新规则 ${plugin.name} 失败',
        error: error,
        stackTrace: stackTrace,
      );
      NotificationToast.show(
        pluginInstallErrorMessage(
          l10n,
          plugin.name,
          error,
          isUpdate: true,
        ),
        title: l10n.updateFailed,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyPluginNames.remove(plugin.name);
        });
      }
    }
  }

  Future<void> _copyPlugin(String name) async {
    final l10n = AppLocalizations.of(context);
    try {
      final content = await _sourceRepository.exportPlugin(name);
      await Clipboard.setData(ClipboardData(text: content));
      if (!mounted) return;
      NotificationToast.show(
        l10n.pluginCopied(name),
        title: l10n.copyPlugin,
      );
    } catch (error) {
      if (!mounted) return;
      NotificationToast.show(
        l10n.pluginCopyFailed(name, error.toString()),
        title: l10n.copyPlugin,
      );
    }
  }

  void _onReorder(int oldIndex, int newIndex) {
    // 先同步更新列表顺序，松手后列表才会立即停在新位置；写入失败时再回滚。
    ref.read(sourceConfigsProvider.notifier).reorder(oldIndex, newIndex);
    _orderWriteChain =
        _orderWriteChain.then((_) => _saveReorder(oldIndex, newIndex));
  }

  Future<void> _saveReorder(int oldIndex, int newIndex) async {
    try {
      await _sourceRepository.reorderSources(oldIndex, newIndex);
    } catch (error, stackTrace) {
      if (!mounted) return;
      LiggLogger().e(
        'Plugins: 数据源排序保存失败',
        error: error,
        stackTrace: stackTrace,
      );
      ref.invalidate(sourceConfigsProvider);
      final l10n = AppLocalizations.of(context);
      NotificationToast.show(
        l10n.dataSaveFailed(error.toString()),
        title: l10n.saveFailed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final paddingOf = MediaQuery.paddingOf(context);
    final sourceConfigs = ref.watch(sourceConfigsProvider);
    final remotePlugins = ref.watch(pluginCatalogProvider).whenOrNull(
              data: (plugins) => plugins,
            ) ??
        const <PluginCatalogItem>[];
    final remotePluginsByName = {
      for (final plugin in remotePlugins) plugin.name: plugin,
    };
    return SettingsPageBuilder(
        builder: (context, glassStyle) => Scaffold(
              extendBodyBehindAppBar: glassStyle,
              appBar: PreferredSize(
                preferredSize: const Size.fromHeight(kToolbarHeight),
                child: Consumer(
                  builder: (context, ref, _) {
                    final isWideScreen = ref.watch(settingsLayoutProvider);
                    return AdaptiveAppBar(
                      glassStyle: glassStyle,
                      title: Text(l10n.sourceManagement),
                      automaticallyImplyLeading: !isWideScreen,
                      actions: [
                        IconButton(
                          tooltip: _showSearch ? '收起搜索' : '搜索源',
                          onPressed: () {
                            setState(() {
                              _showSearch = !_showSearch;
                              if (!_showSearch) {
                                _query = '';
                                _searchController.clear();
                              }
                            });
                          },
                          icon: Icon(
                            _showSearch ? Icons.search_off : Icons.search,
                            size: 28,
                          ),
                        ),
                        IconButton(
                          tooltip: '批量导入',
                          onPressed: _importBatch,
                          icon: const Icon(Icons.playlist_add, size: 28),
                        ),
                        IconButton(
                          tooltip: '一键更新全部',
                          onPressed: _busyPluginNames.isEmpty ? _updateAll : null,
                          icon: const Icon(Icons.system_update_alt, size: 28),
                        ),
                        IconButton(
                          onPressed: () {
                            appNavigatorOf(context).openSettings<void>(
                                destination:
                                    SettingsDestination.downloadPlugins);
                          },
                          icon: const Icon(Icons.cloud_download_outlined,
                              size: 30),
                        ),
                        IconButton(
                          icon: const Icon(Icons.save_as_outlined, size: 30),
                          onPressed: () {
                            appNavigatorOf(context).openPluginEditor<void>();
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
              body: sourceConfigs.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(child: Text(error.toString())),
                data: (dataSources) {
                  final keyword = _query.trim().toLowerCase();
                  final filtered = keyword.isEmpty
                      ? dataSources
                      : [
                          for (final source in dataSources)
                            if (source.name.toLowerCase().contains(keyword) ||
                                source.baseUrl.toLowerCase().contains(keyword))
                              source,
                        ];
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final horizontal =
                          math.max(10.0, (constraints.maxWidth - 1500.0) / 2);
                      final list = ReorderableListView.builder(
                      padding: (EdgeInsets.fromLTRB(
                        horizontal,
                        0,
                        horizontal,
                        paddingOf.bottom,
                      ))
                          .add(EdgeInsets.only(
                              top: SettingsPageBuilder.topInsetOf(context)))
                          .resolve(Directionality.of(context)),
                      itemCount: filtered.length,
                      buildDefaultDragHandles: false,
                      // 筛选状态下下标和真实顺序不一致，直接禁用拖动，避免排错。
                      onReorderItem: _query.isEmpty ? _onReorder : (a, b) {},
                      itemBuilder: (context, index) {
                        final data = filtered[index];
                        final remotePlugin = remotePluginsByName[data.name];
                        final hasUpdate = remotePlugin != null &&
                            Utils.compareVersionNumbers(
                                    remotePlugin.version, data.version) >
                                0;
                        final isPluginBusy =
                            _busyPluginNames.contains(data.name);
                        return InkWell(
                          key: ValueKey(data.name),
                          onTap: () => appNavigatorOf(context)
                              .openPluginEditor<void>(editPluginKey: data.name),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: Theme.of(context)
                                    .disabledColor
                                    .withValues(alpha: 0.1)),
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 5, horizontal: 5),
                                  child: AnimationNetworkImage(
                                      borderRadius: BorderRadius.circular(10),
                                      width: 50,
                                      height: 50,
                                      url: data.iconUrl),
                                ),
                                Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          data.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold),
                                        ),
                                        Row(
                                          children: [
                                            Text(data.version),
                                            if (hasUpdate) ...[
                                              const SizedBox(width: 8),
                                              Text(
                                                l10n.updateAvailable,
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ],
                                        )
                                      ]),
                                ),
                                if (hasUpdate)
                                  TextButton(
                                    onPressed: isPluginBusy
                                        ? null
                                        : () => _updatePlugin(remotePlugin),
                                    child: isPluginBusy
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : Text(l10n.update),
                                  ),
                                IconButton(
                                  tooltip: l10n.copyPlugin,
                                  icon: const Icon(Icons.content_copy_outlined),
                                  onPressed: () => _copyPlugin(data.name),
                                ),
                                IconButton(
                                  tooltip: l10n.delete,
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  onPressed: () => deleteDataSource(data.name),
                                ),
                                if (_query.isEmpty)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {},
                                    child: ReorderableDragStartListener(
                                      index: index,
                                      child: const Padding(
                                        padding:
                                            EdgeInsets.symmetric(horizontal: 8),
                                        child: Icon(Icons.drag_handle),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                      return Column(
                        children: [
                          if (_showSearch)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                              child: TextField(
                                controller: _searchController,
                                autofocus: true,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  prefixIcon: Icon(Icons.search),
                                  hintText: '按名称或域名筛选',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (value) =>
                                    setState(() => _query = value),
                              ),
                            ),
                          Expanded(child: list),
                        ],
                      );
                    },
                  );
                },
              ),
            ));
  }
}
