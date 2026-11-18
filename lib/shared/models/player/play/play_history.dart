import 'package:hive_ce/hive.dart';

part 'play_history.g.dart';

@HiveType(typeId: 2)
class PlayHistory extends HiveObject {
  /// 番剧id
  @HiveField(0)
  int subjectId;

  /// 集id
  @HiveField(1)
  int episodeId;

  /// 集数
  @HiveField(2)
  int episodeSort;

  /// 名称
  @HiveField(3)
  String subjectName;

  /// 封面
  @HiveField(4)
  String cover;

  /// 更新时间
  @HiveField(5)
  DateTime updateAt;

  /// 播放进度
  @HiveField(6)
  int position;

  /// 视频总时长
  @HiveField(7)
  int duration;

  /// 别名
  @HiveField(8)
  List<String> alias;

  /// 是否已同步到服务器。
  @HiveField(9)
  bool isSyncedToServer;

  /// 上次播放使用的数据源名称。
  ///
  /// 为空表示旧记录或本地播放。续播时优先用这个站点，
  /// 避免换到别的源之后进度对不上（不同站点的片头/剪辑可能不同）。
  @HiveField(10)
  String? sourceWebsite;

  PlayHistory({
    required this.subjectId,
    required this.episodeId,
    required this.episodeSort,
    required this.subjectName,
    required this.cover,
    required this.updateAt,
    required this.position,
    required this.duration,
    required this.alias,
    this.isSyncedToServer = false,
    this.sourceWebsite,
  });
}
