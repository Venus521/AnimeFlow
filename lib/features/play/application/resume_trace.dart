import 'dart:collection';

/// 续播链路的运行时探针。
///
/// 只保留最近 [_capacity] 条在内存里，不落盘、不上传。
/// 用途：在手机上直接看清「路由传了什么 → 选到第几集 → 写进记录什么 → 读回来什么」，
/// 把「改完不知道有没有生效」变成「一眼看到断在哪一层」。
class ResumeTrace {
  ResumeTrace._();
  static final ResumeTrace instance = ResumeTrace._();

  static const int _capacity = 80;
  final ListQueue<String> _lines = ListQueue<String>();

  void add(String tag, String message) {
    final now = DateTime.now();
    final ts = '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    _lines.addLast('$ts [$tag] $message');
    while (_lines.length > _capacity) {
      _lines.removeFirst();
    }
  }

  List<String> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;

  String dump() => _lines.isEmpty ? '（还没有记录，先去播一集再回来）' : _lines.join('\n');

  void clear() => _lines.clear();

  static String _two(int value) => value.toString().padLeft(2, '0');
}
