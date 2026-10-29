import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ===== models.dart =====
/// نماذج البيانات (تتحول إلى JSON للتخزين المحلي).

String dateKey(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

DateTime parseKey(String key) {
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

/// بداية الأسبوع (السبت) للتاريخ المعطى.
DateTime weekStart(DateTime d) {
  final offset = (d.weekday + 1) % 7; // السبت=0 ... الجمعة=6
  return DateTime(d.year, d.month, d.day - offset);
}

/// صياغة عربية للأيام: يوم / يومين / 3 أيام / 11 يوم.
String daysText(int n) {
  if (n == 1) return 'يوم';
  if (n == 2) return 'يومين';
  if (n >= 3 && n <= 10) return '$n أيام';
  return '$n يوم';
}

int clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

double clampD(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// تحويل الأرقام إلى صيغة نصية بفواصل (مثال: 8,000).
String fmtInt(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String fmtDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// أنواع المهام: العادية، أو المرتبطة بعدّاد الماء، أو بالتمرين.
class TaskKind {
  static const manual = 'manual';
  static const water = 'water';
  static const workout = 'workout';
}

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    this.archived = false,
    this.kind = TaskKind.manual,
  });

  final String id;
  String title;
  final String kind;

  /// المهمة المؤرشفة تختفي من قائمة اليوم لكن تبقى ظاهرة في السجل القديم.
  bool archived;

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'archived': archived, 'kind': kind};

  factory TaskItem.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    String kind = (j['kind'] as String?) ?? TaskKind.manual;
    // ترقية بيانات النسخة الأولى.
    if (j['kind'] == null) {
      if (id == 'default_0') kind = TaskKind.water;
      if (id == 'default_2') kind = TaskKind.workout;
    }
    return TaskItem(
      id: id,
      title: j['title'] as String,
      archived: (j['archived'] as bool?) ?? false,
      kind: kind,
    );
  }
}

class DayRecord {
  DayRecord({
    Set<String>? done,
    this.steps = 0,
    this.goal = 8000,
    this.total = 0,
    this.water = 0,
    this.rest = false,
  }) : done = done ?? <String>{};

  /// معرّفات المهام المنفّذة في اليوم.
  final Set<String> done;
  int steps;
  int goal;

  /// عدد المهام النشطة وقت تسجيل اليوم.
  int total;

  /// عدد أكواب الماء.
  int water;

  /// يوم راحة معلن (لا يكسر السلسلة).
  bool rest;

  bool get tasksComplete => total > 0 && done.length >= total;
  bool get goalReached => goal > 0 && steps >= goal;
  double get taskProgress =>
      total == 0 ? 0.0 : clampD(done.length / total, 0.0, 1.0);
  bool get isEmpty =>
      done.isEmpty && steps == 0 && water == 0 && !rest;

  Map<String, dynamic> toJson() => {
        'done': done.toList(),
        'steps': steps,
        'goal': goal,
        'total': total,
        'water': water,
        'rest': rest,
      };

  factory DayRecord.fromJson(Map<String, dynamic> j) => DayRecord(
        done: ((j['done'] as List?) ?? const []).cast<String>().toSet(),
        steps: (j['steps'] as int?) ?? 0,
        goal: (j['goal'] as int?) ?? 8000,
        total: (j['total'] as int?) ?? 0,
        water: (j['water'] as int?) ?? 0,
        rest: (j['rest'] as bool?) ?? false,
      );
}

class RunRecord {
  RunRecord({
    required this.start,
    required this.seconds,
    required this.steps,
    required this.km,
    required this.kcal,
  });

  final DateTime start;
  final int seconds;
  final int steps;
  final double km;
  final int kcal;

  /// السرعة المتوسطة كم/س.
  double get speedKmh => seconds == 0 ? 0 : km / (seconds / 3600);

  Map<String, dynamic> toJson() => {
        'start': start.toIso8601String(),
        'seconds': seconds,
        'steps': steps,
        'km': km,
        'kcal': kcal,
      };

  factory RunRecord.fromJson(Map<String, dynamic> j) {
    final steps = j['steps'] as int;
    return RunRecord(
      start: DateTime.parse(j['start'] as String),
      seconds: j['seconds'] as int,
      steps: steps,
      km: (j['km'] as num?)?.toDouble() ?? steps * 0.75 / 1000,
      kcal: (j['kcal'] as int?) ?? (steps * 0.04).round(),
    );
  }
}

class WeightEntry {
  WeightEntry({required this.key, required this.kg});

  final String key; // yyyy-MM-dd
  final double kg;

  Map<String, dynamic> toJson() => {'key': key, 'kg': kg};

  factory WeightEntry.fromJson(Map<String, dynamic> j) =>
      WeightEntry(key: j['key'] as String, kg: (j['kg'] as num).toDouble());
}

/// البيانات الشخصية المستخدمة لحساب المسافة والسعرات بدقة أفضل.
class Profile {
  Profile({this.heightCm = 170, this.weightKg = 70, this.male = true});

  double heightCm;
  double weightKg;
  bool male;

  /// طول الخطوة بالمتر (تقدير: الطول × 0.415).
  double get strideM => heightCm * 0.415 / 100;

  /// سعرات الخطوة الواحدة (تقدير: 0.00057 × الوزن).
  double get kcalPerStep => 0.00057 * weightKg;

  double kmFor(int steps) => steps * strideM / 1000;
  int kcalFor(int steps) => (steps * kcalPerStep).round();

  Map<String, dynamic> toJson() =>
      {'height': heightCm, 'weight': weightKg, 'male': male};

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        heightCm: (j['height'] as num?)?.toDouble() ?? 170,
        weightKg: (j['weight'] as num?)?.toDouble() ?? 70,
        male: (j['male'] as bool?) ?? true,
      );
}


// ===== workout_plan.dart =====
/// خطة التمارين الأسبوعية حسب المستوى (مأخوذة من دليل اللياقة).

enum Level { beginner, intermediate, pro }

extension LevelX on Level {
  String get label => switch (this) {
        Level.beginner => 'مبتدئ',
        Level.intermediate => 'متوسط',
        Level.pro => 'محترف',
      };

  static Level parse(String? s) {
    for (final l in Level.values) {
      if (l.name == s) return l;
    }
    return Level.beginner;
  }
}

class WorkoutDay {
  const WorkoutDay(this.title, this.exercises, {this.rest = false});

  final String title;
  final List<String> exercises;
  final bool rest;
}

const _rest = WorkoutDay('يوم راحة', [], rest: true);

const _fullBody = WorkoutDay('Full Body — كامل الجسم', [
  'ضغط (Push-up): 3 × 8-12',
  'سكوات بوزن الجسم: 3 × 12-15',
  'سحب / عقلة مساعدة: 3 × 5-8',
  'بلانك: 3 × 20-30 ثانية',
  'لانجز: 3 × 10 لكل رجل',
  'جسر المؤخرة: 3 × 15',
]);

const _upper = WorkoutDay('الجزء العلوي', [
  'بنش برس / دامبل برس: 4 × 8-10',
  'عقلة (Pull-up): 4 × 6-10',
  'تجديف بالبار: 3 × 8-10',
  'ضغط كتف (Overhead Press): 3 × 8-10',
  'بايسبس + ترايسبس: 3 × 10-12',
]);

const _lower = WorkoutDay('الجزء السفلي', [
  'سكوات بالبار: 4 × 6-10',
  'رفعة ميتة (Deadlift) — بحذر: 3 × 5-8',
  'لانجز: 3 × 10 لكل رجل',
  'سمانة: 4 × 12-15',
  'بطن: 3 × 15',
]);

const _push = WorkoutDay('Push — صدر + كتف + ترايسبس', [
  'بنش برس: 4 × 6-10',
  'ضغط كتف: 4 × 8-10',
  'Incline Dumbbell Press: 3 × 8-12',
  'رفرفة جانبية: 3 × 12-15',
  'ترايسبس: 3 × 10-12',
]);

const _pull = WorkoutDay('Pull — ظهر + بايسبس', [
  'عقلة: 4 × 6-10',
  'تجديف بالبار: 4 × 8-10',
  'Lat Pulldown: 3 × 10-12',
  'Face Pull / Traps: 3 × 12-15',
  'بايسبس: 3 × 10-12',
]);

const _legs = WorkoutDay('Legs — الرجلين + البطن', [
  'سكوات: 4 × 6-10',
  'رفعة رومانية: 3 × 8-10',
  'ضغط الرجلين: 3 × 10-12',
  'سمانة: 4 × 12-15',
  'بطن: 3 × 15',
]);

/// الجدول الأسبوعي: الفهرس 0=السبت ... 6=الجمعة.
const Map<Level, List<WorkoutDay>> kSchedule = {
  Level.beginner: [_fullBody, _rest, _fullBody, _rest, _fullBody, _rest, _rest],
  Level.intermediate: [_upper, _lower, _rest, _upper, _lower, _rest, _rest],
  Level.pro: [_push, _pull, _legs, _push, _pull, _legs, _rest],
};

WorkoutDay workoutFor(Level level, DateTime day) {
  final index = (day.weekday + 1) % 7; // السبت=0
  return kSchedule[level]![index];
}

const String kWarmup =
    'تسخين 5 دقائق: دوران الكتفين والحوض، High Knees، Jumping Jacks.';
const String kCooldown =
    'بعد التمرين: 10 دقائق تمدد ثابت (Cobra، Cat-Cow، خلف وأمام الفخذ، Child\'s Pose).';


// ===== app_state.dart =====
enum StepStatus { starting, active, denied, unavailable }

class StreakBadge {
  const StreakBadge(this.days, this.title, this.emoji);
  final int days;
  final String title;
  final String emoji;
}

const List<StreakBadge> kBadges = [
  StreakBadge(3, '٣ أيام متواصلة', '🌱'),
  StreakBadge(7, 'شارة الأسبوع', '🔥'),
  StreakBadge(14, 'أسبوعين', '⚡'),
  StreakBadge(30, 'شارة الشهر', '🏆'),
  StreakBadge(100, '١٠٠ يوم', '👑'),
];

typedef WeekSummary = ({
  int fullDays,
  int restDays,
  int steps,
  int goalDays,
  int runCount,
  double km,
});

class AppState extends ChangeNotifier {
  AppState(this._prefs);

  final SharedPreferences _prefs;

  List<TaskItem> tasks = [];
  final Map<String, DayRecord> days = {};
  List<RunRecord> runs = [];
  List<WeightEntry> weights = [];
  Profile profile = Profile();

  int stepGoal = 8000;
  int waterGoal = 8; // أكواب (250 مل للكوب)
  Level level = Level.beginner;
  ThemeMode themeMode = ThemeMode.system;

  StepStatus stepStatus = StepStatus.starting;

  int? _lastRaw;
  StreamSubscription<StepCount>? _sub;
  Timer? _saveTimer;
  Timer? _midnightTimer;

  // ---- وضع الجري/المشي ----
  bool runActive = false; // الجلسة بدأت (حتى لو متوقفة مؤقتاً)
  bool runPaused = false;
  int runSteps = 0;
  DateTime? runStart;
  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;

  int get runSeconds => _watch.elapsed.inSeconds;
  double get runKm => profile.kmFor(runSteps);
  int get runKcal => profile.kcalFor(runSteps);

  // ---------------------------------------------------------------
  // التحميل والحفظ
  // ---------------------------------------------------------------

  void load() {
    try {
      final m = <String, dynamic>{};
      for (final k in const ['tasks', 'days', 'runs', 'weights', 'settings']) {
        final raw = _prefs.getString(k);
        if (raw != null) m[k] = jsonDecode(raw);
      }
      // ترقية من النسخة الأولى (كان الهدف محفوظاً بمفتاح مستقل).
      if (m['settings'] == null && _prefs.getInt('stepGoal') != null) {
        m['settings'] = {'stepGoal': _prefs.getInt('stepGoal')};
      }
      _applyMap(m);
    } catch (_) {
      // بيانات تالفة: نبدأ بحالة نظيفة بدل أن يتعطل التطبيق.
      _applyMap(const {});
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      _lastRaw = _prefs.getInt('lastRaw');
    }
    _scheduleMidnight();
  }

  /// يطبّق بيانات (من التخزين أو من نسخة احتياطية). يرمي استثناء لو الشكل غلط
  /// دون أن يغيّر الحالة الحالية.
  void _applyMap(Map<String, dynamic> m) {
    final newTasks = ((m['tasks'] as List?) ?? const [])
        .map((e) => TaskItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final newDays = <String, DayRecord>{};
    ((m['days'] as Map?) ?? const {}).forEach((k, v) {
      newDays[k as String] =
          DayRecord.fromJson(Map<String, dynamic>.from(v as Map));
    });
    final newRuns = ((m['runs'] as List?) ?? const [])
        .map((e) => RunRecord.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final newWeights = ((m['weights'] as List?) ?? const [])
        .map((e) => WeightEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final s = Map<String, dynamic>.from((m['settings'] as Map?) ?? const {});

    tasks = newTasks.isEmpty ? _defaultTasks() : newTasks;
    days
      ..clear()
      ..addAll(newDays);
    runs = newRuns;
    weights = newWeights..sort((a, b) => a.key.compareTo(b.key));
    stepGoal = clampInt((s['stepGoal'] as num?)?.toInt() ?? 8000, 1000, 50000);
    waterGoal = clampInt((s['waterGoal'] as num?)?.toInt() ?? 8, 1, 20);
    level = LevelX.parse(s['level'] as String?);
    themeMode = _themeFrom(s['theme'] as String?);
    profile = s['profile'] is Map
        ? Profile.fromJson(Map<String, dynamic>.from(s['profile'] as Map))
        : Profile();
  }

  ThemeMode _themeFrom(String? s) {
    for (final t in ThemeMode.values) {
      if (t.name == s) return t;
    }
    return ThemeMode.system;
  }

  List<TaskItem> _defaultTasks() {
    const titles = [
      '💧 شرب 2-3 لتر ماء',
      '🧘 10 دقائق تمدد صباحي',
      '🏋️ تمرين اليوم (حسب الجدول)',
      '🤸 10 دقائق تمدد بعد التمرين',
      '🍗 الوصول لهدف البروتين',
      '😴 النوم 7-9 ساعات',
      '🚶 المشي 30 دقيقة',
    ];
    return [
      for (var i = 0; i < titles.length; i++)
        TaskItem(
          id: 'default_$i',
          title: titles[i],
          kind: i == 0
              ? TaskKind.water
              : (i == 2 ? TaskKind.workout : TaskKind.manual),
        ),
    ];
  }

  Map<String, dynamic> _settingsMap() => {
        'stepGoal': stepGoal,
        'waterGoal': waterGoal,
        'level': level.name,
        'theme': themeMode.name,
        'profile': profile.toJson(),
      };

  Future<void> _saveTasks() => _prefs.setString(
      'tasks', jsonEncode(tasks.map((t) => t.toJson()).toList()));

  Future<void> _saveDays() => _prefs.setString(
      'days', jsonEncode(days.map((k, v) => MapEntry(k, v.toJson()))));

  Future<void> _saveRuns() => _prefs.setString(
      'runs', jsonEncode(runs.map((r) => r.toJson()).toList()));

  Future<void> _saveWeights() => _prefs.setString(
      'weights', jsonEncode(weights.map((w) => w.toJson()).toList()));

  Future<void> _saveSettings() =>
      _prefs.setString('settings', jsonEncode(_settingsMap()));

  /// حفظ مؤجّل لسجل الأيام: الخطوات بتيجي بسرعة فمنكتبش على الذاكرة كل مرة.
  void _scheduleSaveDays() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), flush);
  }

  /// يكتب أي تغييرات معلّقة فوراً (يُستدعى عند خروج التطبيق للخلفية).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _saveDays();
    final raw = _lastRaw;
    if (raw != null && defaultTargetPlatform == TargetPlatform.android) {
      await _prefs.setInt('lastRaw', raw);
    }
  }

  Future<void> _saveAll() async {
    await _saveTasks();
    await _saveDays();
    await _saveRuns();
    await _saveWeights();
    await _saveSettings();
  }

  // ---------------------------------------------------------------
  // دورة حياة التطبيق واليوم الجديد
  // ---------------------------------------------------------------

  void _scheduleMidnight() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month, now.day + 1, 0, 0, 2);
    _midnightTimer = Timer(next.difference(now), () {
      notifyListeners();
      _scheduleMidnight();
    });
  }

  void onResumed() {
    _scheduleMidnight(); // ممكن يكون اليوم اتغيّر والتطبيق في الخلفية
    notifyListeners();
    if (stepStatus == StepStatus.denied) initSteps();
  }

  // ---------------------------------------------------------------
  // المهام
  // ---------------------------------------------------------------

  String get todayKey => dateKey(DateTime.now());

  List<TaskItem> get activeTasks => tasks.where((t) => !t.archived).toList();

  TaskItem? taskById(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  DayRecord _todayRecord() {
    final rec = days.putIfAbsent(todayKey, () => DayRecord(goal: stepGoal));
    rec.total = activeTasks.length;
    return rec;
  }

  /// سجل اليوم الحالي (بدون إنشاء سجل جديد إن لم يوجد).
  DayRecord get today {
    final rec = days[todayKey];
    if (rec == null) {
      return DayRecord(goal: stepGoal, total: activeTasks.length);
    }
    rec.total = activeTasks.length;
    return rec;
  }

  bool isDoneToday(String id) => days[todayKey]?.done.contains(id) ?? false;

  /// يعكس حالة المهمة. ترجع true لو الضغطة دي هي اللي كمّلت كل مهام اليوم.
  bool toggleTask(String id) {
    final rec = _todayRecord();
    final before = rec.tasksComplete;
    final t = taskById(id);
    if (rec.done.add(id)) {
      if (t?.kind == TaskKind.water && rec.water < waterGoal) {
        rec.water = waterGoal;
      }
    } else {
      rec.done.remove(id);
      if (t?.kind == TaskKind.water && rec.water >= waterGoal) {
        rec.water = waterGoal - 1;
      }
    }
    notifyListeners();
    _scheduleSaveDays();
    return !before && rec.tasksComplete;
  }

  /// يعتبر مهام "التمرين" منجزة (مثلاً في يوم الراحة المجدولة).
  bool completeWorkoutTasks() {
    final rec = _todayRecord();
    final before = rec.tasksComplete;
    for (final t in activeTasks) {
      if (t.kind == TaskKind.workout) rec.done.add(t.id);
    }
    notifyListeners();
    _scheduleSaveDays();
    return !before && rec.tasksComplete;
  }

  Future<void> addTask(String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    tasks.add(TaskItem(
        id: 'custom_${DateTime.now().microsecondsSinceEpoch}', title: t));
    final rec = days[todayKey];
    if (rec != null) rec.total = activeTasks.length;
    notifyListeners();
    await _saveTasks();
    _scheduleSaveDays();
  }

  Future<void> renameTask(String id, String title) async {
    final t = taskById(id);
    final n = title.trim();
    if (t == null || n.isEmpty) return;
    t.title = n;
    notifyListeners();
    await _saveTasks();
  }

  Future<void> archiveTask(String id) async {
    final t = taskById(id);
    if (t == null) return;
    t.archived = true;
    final rec = days[todayKey];
    if (rec != null) rec.total = activeTasks.length;
    notifyListeners();
    await _saveTasks();
    _scheduleSaveDays();
  }

  Future<void> restoreTask(String id) async {
    final t = taskById(id);
    if (t == null) return;
    t.archived = false;
    final rec = days[todayKey];
    if (rec != null) rec.total = activeTasks.length;
    notifyListeners();
    await _saveTasks();
    _scheduleSaveDays();
  }

  // ---------------------------------------------------------------
  // الماء
  // ---------------------------------------------------------------

  int get waterToday => days[todayKey]?.water ?? 0;

  void _syncWaterTask(DayRecord rec) {
    for (final t in tasks) {
      if (t.kind != TaskKind.water || t.archived) continue;
      if (rec.water >= waterGoal) {
        rec.done.add(t.id);
      } else {
        rec.done.remove(t.id);
      }
    }
  }

  /// يضيف/يشيل أكواب. ترجع true لو ده كمّل كل مهام اليوم.
  bool addWater(int delta) {
    final rec = _todayRecord();
    final before = rec.tasksComplete;
    rec.water = clampInt(rec.water + delta, 0, 40);
    _syncWaterTask(rec);
    notifyListeners();
    _scheduleSaveDays();
    return !before && rec.tasksComplete;
  }

  Future<void> setWaterGoal(int glasses) async {
    waterGoal = clampInt(glasses, 1, 20);
    final rec = days[todayKey];
    if (rec != null) _syncWaterTask(rec);
    notifyListeners();
    await _saveSettings();
    _scheduleSaveDays();
  }

  // ---------------------------------------------------------------
  // يوم الراحة (لا يكسر السلسلة) — مسموح يوم واحد في الأسبوع
  // ---------------------------------------------------------------

  /// مفتاح يوم الراحة المعلن في هذا الأسبوع (السبت–الجمعة)، أو null.
  String? get restKeyThisWeek {
    final start = weekStart(DateTime.now());
    for (var i = 0; i < 7; i++) {
      final k = dateKey(DateTime(start.year, start.month, start.day + i));
      if (days[k]?.rest ?? false) return k;
    }
    return null;
  }

  bool get isRestToday => days[todayKey]?.rest ?? false;

  bool get canMarkRestToday => isRestToday || restKeyThisWeek == null;

  /// ترجع false لو مفيش رصيد راحة هذا الأسبوع.
  bool toggleRestToday() {
    if (!canMarkRestToday) return false;
    final rec = _todayRecord();
    rec.rest = !rec.rest;
    notifyListeners();
    _scheduleSaveDays();
    return true;
  }

  // ---------------------------------------------------------------
  // الخطة
  // ---------------------------------------------------------------

  WorkoutDay get todayWorkout => workoutFor(level, DateTime.now());

  Future<void> setLevel(Level l) async {
    level = l;
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await _saveSettings();
  }

  Future<void> updateProfile({double? heightCm, bool? male}) async {
    if (heightCm != null && heightCm >= 100 && heightCm <= 230) {
      profile.heightCm = heightCm;
    }
    if (male != null) profile.male = male;
    notifyListeners();
    await _saveSettings();
  }

  // ---------------------------------------------------------------
  // الوزن
  // ---------------------------------------------------------------

  double? get latestWeight => weights.isEmpty ? null : weights.last.kg;

  /// التغيّر منذ أول قياس (موجب = زيادة).
  double? get weightChange =>
      weights.length < 2 ? null : weights.last.kg - weights.first.kg;

  Future<void> addWeight(double kg) async {
    if (kg < 25 || kg > 300) return;
    weights.removeWhere((w) => w.key == todayKey);
    weights.add(WeightEntry(key: todayKey, kg: kg));
    weights.sort((a, b) => a.key.compareTo(b.key));
    profile.weightKg = kg;
    notifyListeners();
    await _saveWeights();
    await _saveSettings();
  }

  Future<void> removeWeight(String key) async {
    weights.removeWhere((w) => w.key == key);
    if (weights.isNotEmpty) profile.weightKg = weights.last.kg;
    notifyListeners();
    await _saveWeights();
    await _saveSettings();
  }

  // ---------------------------------------------------------------
  // الخطوات
  // ---------------------------------------------------------------

  int get todaySteps => days[todayKey]?.steps ?? 0;

  Future<void> setStepGoal(int goal) async {
    stepGoal = clampInt(goal, 1000, 50000);
    final rec = days[todayKey];
    if (rec != null) rec.goal = stepGoal;
    notifyListeners();
    await _saveSettings();
    _scheduleSaveDays();
  }

  Future<void> initSteps() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      stepStatus = StepStatus.unavailable;
      notifyListeners();
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final st = await Permission.activityRecognition.request();
      if (!st.isGranted) {
        stepStatus = StepStatus.denied;
        notifyListeners();
        return;
      }
    }

    await _sub?.cancel();
    try {
      _sub = Pedometer.stepCountStream.listen(
        _onStep,
        onError: (Object _) {
          stepStatus = StepStatus.unavailable;
          notifyListeners();
        },
        cancelOnError: false,
      );
      stepStatus = StepStatus.active;
    } catch (_) {
      stepStatus = StepStatus.unavailable;
    }
    notifyListeners();
  }

  void _onStep(StepCount e) {
    final raw = e.steps;
    var delta = 0;
    final last = _lastRaw;
    if (last != null) {
      // لو الرقم صغر معناها الجهاز اتعمله إعادة تشغيل والعداد بدأ من صفر.
      delta = raw >= last ? raw - last : raw;
    }
    _lastRaw = raw;
    // حماية من قفزات غير منطقية.
    if (delta > 0 && delta < 40000) {
      _addSteps(delta, fromSensor: true);
    } else {
      _scheduleSaveDays(); // يحفظ lastRaw
    }
  }

  void _addSteps(int n, {required bool fromSensor}) {
    final rec = _todayRecord();
    rec.goal = stepGoal;
    rec.steps += n;
    if (fromSensor && runActive && !runPaused) runSteps += n;
    notifyListeners();
    _scheduleSaveDays();
  }

  /// إضافة/تصحيح خطوات يدوياً (للأجهزة بدون حساس أو لتصحيح العدد).
  void addManualSteps(int n) {
    if (n == 0) return;
    if (n < 0) {
      final rec = _todayRecord();
      rec.steps = clampInt(rec.steps + n, 0, 1000000);
      notifyListeners();
      _scheduleSaveDays();
    } else {
      _addSteps(n, fromSensor: false);
    }
  }

  // ---------------------------------------------------------------
  // وضع الجري
  // ---------------------------------------------------------------

  void startRun() {
    runActive = true;
    runPaused = false;
    runSteps = 0;
    runStart = DateTime.now();
    _watch
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker =
        Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
  }

  void pauseRun() {
    if (!runActive || runPaused) return;
    runPaused = true;
    _watch.stop();
    notifyListeners();
  }

  void resumeRun() {
    if (!runActive || !runPaused) return;
    runPaused = false;
    _watch.start();
    notifyListeners();
  }

  /// إنهاء الجلسة وحفظها. ترجع الجلسة (أو null لو كانت قصيرة جداً).
  Future<RunRecord?> finishRun() async {
    if (!runActive) return null;
    _watch.stop();
    _ticker?.cancel();
    final seconds = _watch.elapsed.inSeconds;
    RunRecord? saved;
    if (seconds >= 10) {
      saved = RunRecord(
        start: runStart ?? DateTime.now(),
        seconds: seconds,
        steps: runSteps,
        km: profile.kmFor(runSteps),
        kcal: profile.kcalFor(runSteps),
      );
      runs.insert(0, saved);
    }
    runActive = false;
    runPaused = false;
    runSteps = 0;
    runStart = null;
    _watch.reset();
    notifyListeners();
    if (saved != null) await _saveRuns();
    return saved;
  }

  List<RunRecord> runsOn(String key) =>
      runs.where((r) => dateKey(r.start) == key).toList();

  // ---------------------------------------------------------------
  // السلاسل والإحصائيات
  // ---------------------------------------------------------------

  bool isFullDay(String key) => days[key]?.tasksComplete ?? false;
  bool isRestDay(String key) => days[key]?.rest ?? false;

  /// السلسلة الحالية: يوم كامل = +1، يوم راحة = يعدّي بدون ما يكسر،
  /// واليوم الحالي غير المكتمل لا يكسر السلسلة (لسه عندك وقت).
  int get streak {
    final n0 = DateTime.now();
    var d = DateTime(n0.year, n0.month, n0.day);
    var count = 0;
    var first = true;
    for (var i = 0; i < 4000; i++) {
      final k = dateKey(d);
      if (isFullDay(k)) {
        count++;
      } else if (isRestDay(k)) {
        // يوم راحة: بدون زيادة وبدون كسر
      } else if (!first) {
        break;
      }
      first = false;
      d = DateTime(d.year, d.month, d.day - 1);
    }
    return count;
  }

  int get bestStreak {
    final keys = days.keys.where((k) => isFullDay(k) || isRestDay(k)).toList()
      ..sort();
    if (keys.isEmpty) return 0;
    final n0 = DateTime.now();
    final todayD = DateTime(n0.year, n0.month, n0.day);
    var d = parseKey(keys.first);
    var best = 0, cur = 0;
    while (!d.isAfter(todayD)) {
      final k = dateKey(d);
      if (isFullDay(k)) {
        cur++;
        if (cur > best) best = cur;
      } else if (isRestDay(k)) {
        // لا شيء
      } else if (d != todayD) {
        cur = 0;
      }
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return best;
  }

  int get fullDaysCount => days.keys.where(isFullDay).length;

  int get goalDaysCount => days.values.where((r) => r.goalReached).length;

  int get totalSteps => days.values.fold(0, (a, r) => a + r.steps);

  /// ملخص آخر 7 أيام (شامل اليوم).
  WeekSummary lastSevenDays() {
    final n0 = DateTime.now();
    var full = 0, rest = 0, steps = 0, goalDays = 0, runCount = 0;
    var km = 0.0;
    for (var i = 0; i < 7; i++) {
      final d = DateTime(n0.year, n0.month, n0.day - i);
      final k = dateKey(d);
      final r = days[k];
      if (r != null) {
        if (r.tasksComplete) full++;
        if (r.rest) rest++;
        steps += r.steps;
        if (r.goalReached) goalDays++;
      }
      for (final run in runsOn(k)) {
        runCount++;
        km += run.km;
      }
    }
    return (
      fullDays: full,
      restDays: rest,
      steps: steps,
      goalDays: goalDays,
      runCount: runCount,
      km: km,
    );
  }

  // ---------------------------------------------------------------
  // نسخ احتياطي / استعادة / مسح
  // ---------------------------------------------------------------

  String exportJson() => jsonEncode({
        'version': 2,
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'days': days.map((k, v) => MapEntry(k, v.toJson())),
        'runs': runs.map((r) => r.toJson()).toList(),
        'weights': weights.map((w) => w.toJson()).toList(),
        'settings': _settingsMap(),
      });

  Future<bool> importJson(String raw) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] == null) return false;
      _applyMap(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return false;
    }
    await _saveAll();
    notifyListeners();
    return true;
  }

  Future<void> resetAll() async {
    _saveTimer?.cancel();
    if (runActive) {
      _watch.stop();
      _ticker?.cancel();
      runActive = false;
      runPaused = false;
      runSteps = 0;
      _watch.reset();
    }
    _applyMap(const {});
    await _saveAll();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _saveTimer?.cancel();
    _midnightTimer?.cancel();
    super.dispose();
  }
}


// ===== screens/today_screen.dart =====
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key, required this.state});

  final AppState state;

  void _celebrate(BuildContext context) {
    HapticFeedback.heavyImpact();
    final m = ScaffoldMessenger.of(context);
    m.clearSnackBars();
    m.showSnackBar(const SnackBar(
      content: Text('🎉 ما شاء الله! خلّصت كل مهام النهارده — السلسلة زادت 🔥'),
    ));
  }

  void _toggle(BuildContext context, String id) {
    HapticFeedback.selectionClick();
    if (state.toggleTask(id)) _celebrate(context);
  }

  Future<String?> _askText(
    BuildContext context, {
    required String title,
    String initial = '',
    String hint = '',
    String action = 'حفظ',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(action)),
        ],
      ),
    );
  }

  Future<void> _addTask(BuildContext context) async {
    final title = await _askText(context,
        title: 'مهمة جديدة', hint: 'مثال: 20 دقيقة كارديو', action: 'إضافة');
    if (title != null && title.trim().isNotEmpty) await state.addTask(title);
  }

  Future<void> _renameTask(BuildContext context, TaskItem t) async {
    final title = await _askText(context, title: 'تعديل المهمة', initial: t.title);
    if (title != null && title.trim().isNotEmpty) {
      await state.renameTask(t.id, title);
    }
  }

  void _archive(BuildContext context, TaskItem t) {
    state.archiveTask(t.id);
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: const Text('تم حذف المهمة'),
      action: SnackBarAction(
          label: 'تراجع', onPressed: () => state.restoreTask(t.id)),
    ));
  }

  void _toggleRest(BuildContext context) {
    final ok = state.toggleRestToday();
    final m = ScaffoldMessenger.of(context);
    m.clearSnackBars();
    if (!ok) {
      m.showSnackBar(const SnackBar(
          content: Text('استخدمت يوم الراحة بتاع الأسبوع ده بالفعل (يوم واحد في الأسبوع).')));
    } else if (state.isRestToday) {
      m.showSnackBar(const SnackBar(
          content: Text('😴 يوم راحة — السلسلة محفوظة. ارتاح وارجع بكرة أقوى!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final tasks = state.activeTasks;
    final doneCount = tasks.where((t) => state.isDoneToday(t.id)).length;
    final progress = tasks.isEmpty ? 0.0 : doneCount / tasks.length;
    final allDone = tasks.isNotEmpty && doneCount == tasks.length;
    final dateText = DateFormat('EEEE d MMMM', 'ar').format(DateTime.now());
    final streak = state.streak;
    final rest = state.isRestToday;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addTask(context),
        icon: const Icon(Icons.add),
        label: const Text('مهمة'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('أهلاً بيك 👋', style: tt.headlineSmall),
                    Text(dateText,
                        style: tt.bodyMedium?.copyWith(color: cs.outline)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'الإعدادات',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(state: state)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: allDone ? cs.primaryContainer : cs.surfaceVariant,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    height: 84,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 9,
                            backgroundColor: cs.surface,
                          ),
                        ),
                        Text('${(progress * 100).round()}%',
                            style: tt.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rest
                              ? '😴 النهارده يوم راحة'
                              : allDone
                                  ? 'ما شاء الله! خلّصت كل مهامك 🎉'
                                  : 'خلّصت $doneCount من ${tasks.length} مهام',
                          style: tt.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.local_fire_department,
                                size: 20,
                                color: streak > 0
                                    ? Colors.deepOrange
                                    : cs.outline),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                streak > 0
                                    ? 'سلسلة ${daysText(streak)} متواصلة'
                                    : 'ابدأ سلسلتك النهارده',
                                style: tt.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _WorkoutCard(state: state, onDone: () {
            if (state.completeWorkoutTasks()) _celebrate(context);
          }),
          const SizedBox(height: 12),
          _WaterCard(
            state: state,
            onChange: (d) {
              HapticFeedback.selectionClick();
              if (state.addWater(d)) _celebrate(context);
            },
          ),
          const SizedBox(height: 12),
          _StepsMiniCard(state: state),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: Text('مهام اليوم', style: tt.titleMedium)),
              TextButton.icon(
                onPressed: () => _toggleRest(context),
                icon: Icon(rest ? Icons.undo : Icons.bedtime_outlined, size: 18),
                label: Text(rest ? 'إلغاء الراحة' : 'يوم راحة'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('مفيش مهام. اضغط "مهمة" لإضافة واحدة.',
                    style: tt.bodyMedium?.copyWith(color: cs.outline)),
              ),
            ),
          for (final t in tasks)
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              color: state.isDoneToday(t.id)
                  ? cs.primaryContainer.withOpacity(0.6)
                  : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: GestureDetector(
                onLongPress: () => _renameTask(context, t),
                child: CheckboxListTile(
                  value: state.isDoneToday(t.id),
                  onChanged: (_) => _toggle(context, t.id),
                  controlAffinity: ListTileControlAffinity.leading,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  title: Text(
                    t.title,
                    style: TextStyle(
                      decoration: state.isDoneToday(t.id)
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  subtitle: t.kind == TaskKind.water
                      ? Text('${state.waterToday} / ${state.waterGoal} كوب')
                      : null,
                  secondary: IconButton(
                    tooltip: 'حذف',
                    icon: const Icon(Icons.close),
                    onPressed: () => _archive(context, t),
                  ),
                ),
              ),
            ),
          if (tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('اضغط مطولاً على أي مهمة لتعديل اسمها.',
                  style: tt.bodySmall?.copyWith(color: cs.outline)),
            ),
        ],
      ),
    );
  }
}

class _WorkoutCard extends StatelessWidget {
  const _WorkoutCard({required this.state, required this.onDone});

  final AppState state;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final w = state.todayWorkout;
    final hasWorkoutTask =
        state.activeTasks.any((t) => t.kind == TaskKind.workout);
    final workoutDone = state.activeTasks
        .where((t) => t.kind == TaskKind.workout)
        .every((t) => state.isDoneToday(t.id));

    return Card(
      elevation: 0,
      color: cs.tertiaryContainer,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: false,
        leading: Text(w.rest ? '😴' : '🏋️', style: const TextStyle(fontSize: 24)),
        title: Text('تمرين اليوم — ${state.level.label}', style: tt.titleSmall),
        subtitle: Text(w.title),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (w.rest)
            const Text(
                'النهارده راحة حسب جدولك. العضلات بتتبني وانت بترتاح — ممكن تعمل مشي خفيف وتمدد.')
          else ...[
            const Text(kWarmup, style: TextStyle(height: 1.5)),
            const SizedBox(height: 8),
            for (final e in w.exercises)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• $e'),
              ),
            const SizedBox(height: 8),
            const Text(kCooldown, style: TextStyle(height: 1.5)),
          ],
          if (hasWorkoutTask && w.rest && !workoutDone)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.tonal(
                onPressed: onDone,
                child: const Text('اعتبر مهمة التمرين منجزة (يوم راحة)'),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaterCard extends StatelessWidget {
  const _WaterCard({required this.state, required this.onChange});

  final AppState state;
  final void Function(int delta) onChange;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final n = state.waterToday;
    final goal = state.waterGoal;
    final shown = n > goal ? n : goal;

    return Card(
      elevation: 0,
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('💧 الماء', style: tt.titleMedium),
                const Spacer(),
                Text('$n / $goal كوب  (${(n * 0.25).toStringAsFixed(2)} لتر)',
                    style: tt.bodyMedium),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < shown; i++)
                  Icon(
                    i < n ? Icons.water_drop : Icons.water_drop_outlined,
                    color: i < n ? cs.primary : cs.outline,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: 'نقص كوب',
                  onPressed: n > 0 ? () => onChange(-1) : null,
                  icon: const Icon(Icons.remove),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => onChange(1),
                  icon: const Icon(Icons.add),
                  label: const Text('كوب'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepsMiniCard extends StatelessWidget {
  const _StepsMiniCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final steps = state.todaySteps;
    final goal = state.stepGoal;
    final p = clampD(steps / goal, 0.0, 1.0);
    return Card(
      elevation: 0,
      color: cs.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_walk),
                const SizedBox(width: 8),
                Text('${fmtInt(steps)} / ${fmtInt(goal)} خطوة',
                    style: tt.titleMedium),
                const Spacer(),
                if (steps >= goal) const Text('🏅 تحقق الهدف'),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: p, minHeight: 10),
            ),
          ],
        ),
      ),
    );
  }
}


// ===== screens/steps_screen.dart =====
class StepsScreen extends StatelessWidget {
  const StepsScreen({super.key, required this.state});

  final AppState state;

  Future<void> _editGoal(BuildContext context) async {
    var value = state.stepGoal.toDouble();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('هدف الخطوات اليومي'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmtInt(value.round()),
                  style: Theme.of(ctx)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Text('خطوة في اليوم'),
              Slider(
                value: value,
                min: 1000,
                max: 30000,
                divisions: 58,
                label: fmtInt(value.round()),
                onChanged: (v) => setLocal(() => value = v),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final g in const [5000, 8000, 10000, 12000, 15000])
                    ActionChip(
                      label: Text(fmtInt(g)),
                      onPressed: () => setLocal(() => value = g.toDouble()),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, value.round()),
                child: const Text('حفظ')),
          ],
        ),
      ),
    );
    if (result != null) await state.setStepGoal(result);
  }

  Future<void> _customSteps(BuildContext context) async {
    final c = TextEditingController();
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة خطوات يدوياً'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'عدد الخطوات'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())),
              child: const Text('إضافة')),
        ],
      ),
    );
    if (v != null && v > 0) state.addManualSteps(v);
  }

  Future<void> _finishRun(BuildContext context) async {
    final run = await state.finishRun();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(run == null
          ? 'الجلسة كانت قصيرة جداً فلم تُحفظ'
          : 'تم حفظ الجلسة: ${fmtInt(run.steps)} خطوة • ${run.km.toStringAsFixed(2)} كم 💪'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final steps = state.todaySteps;
    final goal = state.stepGoal;
    final p = clampD(steps / goal, 0.0, 1.0);
    final km = state.profile.kmFor(steps);
    final kcal = state.profile.kcalFor(steps);
    final reached = steps >= goal;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('الخطوات', style: tt.headlineSmall),
        const SizedBox(height: 12),
        if (state.stepStatus == StepStatus.denied)
          _Banner(
            icon: Icons.lock_outline,
            text: 'محتاجين صلاحية "النشاط البدني" عشان نعد خطواتك تلقائياً.',
            actionLabel: 'فتح الإعدادات',
            onAction: openAppSettings,
            color: cs.errorContainer,
          ),
        if (state.stepStatus == StepStatus.unavailable)
          _Banner(
            icon: Icons.sensors_off,
            text: 'حساس الخطوات غير متاح على هذا الجهاز. تقدر تضيف خطواتك يدوياً.',
            color: cs.tertiaryContainer,
          ),
        Card(
          elevation: 0,
          color: reached ? cs.primaryContainer : cs.surfaceVariant,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                SizedBox(
                  width: 200,
                  height: 200,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: p,
                          strokeWidth: 14,
                          backgroundColor: cs.surface,
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(reached ? Icons.emoji_events : Icons.directions_walk,
                              size: 30,
                              color: reached ? Colors.amber.shade700 : cs.primary),
                          Text(fmtInt(steps),
                              style: tt.displaySmall
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          Text('من ${fmtInt(goal)}', style: tt.bodyMedium),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Stat(icon: Icons.route, value: km.toStringAsFixed(2), unit: 'كم'),
                    _Stat(
                        icon: Icons.local_fire_department,
                        value: '$kcal',
                        unit: 'سعرة'),
                    _Stat(
                        icon: Icons.flag,
                        value: '${(p * 100).round()}%',
                        unit: 'من الهدف'),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _editGoal(context),
                  icon: const Icon(Icons.edit),
                  label: const Text('تعديل الهدف اليومي'),
                ),
                if (state.stepStatus != StepStatus.active) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final n in const [100, 500, 1000])
                        ActionChip(
                            label: Text('+${fmtInt(n)}'),
                            onPressed: () => state.addManualSteps(n)),
                      ActionChip(
                          label: const Text('رقم آخر'),
                          onPressed: () => _customSteps(context)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _RunCard(state: state, onFinish: () => _finishRun(context)),
        const SizedBox(height: 16),
        Text('آخر 7 أيام', style: tt.titleMedium),
        const SizedBox(height: 8),
        _WeekBars(state: state),
        if (state.runs.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('آخر جلسات الجري/المشي', style: tt.titleMedium),
          const SizedBox(height: 8),
          for (final r in state.runs.take(5))
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: ListTile(
                leading: const Icon(Icons.directions_run),
                title: Text(
                    '${fmtDuration(r.seconds)} • ${r.km.toStringAsFixed(2)} كم'),
                subtitle: Text(
                    '${fmtInt(r.steps)} خطوة • ${r.kcal} سعرة • ${r.speedKmh.toStringAsFixed(1)} كم/س\n${DateFormat('EEEE d MMMM - h:mm a', 'ar').format(r.start)}'),
                isThreeLine: true,
              ),
            ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.state, required this.onFinish});

  final AppState state;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    if (!state.runActive) {
      return Card(
        elevation: 0,
        color: cs.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('🏃 وضع الجري / المشي', style: tt.titleMedium),
              const SizedBox(height: 6),
              Text(
                'ابدأ جلسة، وهنحسب الوقت والخطوات والمسافة التقريبية والسعرات '
                'من طولك ووزنك (تقدر تظبطهم من الإعدادات).',
                style: tt.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: state.startRun,
                icon: const Icon(Icons.play_arrow),
                label: const Text('ابدأ جلسة'),
              ),
              if (state.stepStatus != StepStatus.active)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'ملاحظة: بدون حساس الخطوات هتتسجل المدة فقط.',
                    style: tt.bodySmall?.copyWith(color: cs.outline),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      color: state.runPaused ? cs.surfaceVariant : cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(state.runPaused ? '⏸ متوقفة مؤقتاً' : '🏃 الجلسة شغالة',
                style: tt.titleMedium),
            const SizedBox(height: 8),
            Text(fmtDuration(state.runSeconds),
                style: tt.displayMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Stat(
                    icon: Icons.directions_walk,
                    value: fmtInt(state.runSteps),
                    unit: 'خطوة'),
                _Stat(
                    icon: Icons.route,
                    value: state.runKm.toStringAsFixed(2),
                    unit: 'كم'),
                _Stat(
                    icon: Icons.local_fire_department,
                    value: '${state.runKcal}',
                    unit: 'سعرة'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        state.runPaused ? state.resumeRun : state.pauseRun,
                    icon: Icon(state.runPaused ? Icons.play_arrow : Icons.pause),
                    label: Text(state.runPaused ? 'استئناف' : 'إيقاف مؤقت'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onFinish,
                    style: FilledButton.styleFrom(
                        backgroundColor: cs.error, foregroundColor: cs.onError),
                    icon: const Icon(Icons.stop),
                    label: const Text('إنهاء'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekBars extends StatelessWidget {
  const _WeekBars({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final now = DateTime.now();
    final items = <({String label, int steps, int goal})>[];
    for (var i = 6; i >= 0; i--) {
      final d = DateTime(now.year, now.month, now.day - i);
      final rec = state.days[dateKey(d)];
      items.add((
        label: DateFormat('E', 'ar').format(d),
        steps: rec?.steps ?? 0,
        goal: rec?.goal ?? state.stepGoal,
      ));
    }
    var maxV = state.stepGoal;
    for (final it in items) {
      if (it.steps > maxV) maxV = it.steps;
      if (it.goal > maxV) maxV = it.goal;
    }
    const barArea = 110.0;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final it in items)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(it.steps == 0 ? '' : '${(it.steps / 1000).toStringAsFixed(1)}k',
                        style: tt.labelSmall),
                    const SizedBox(height: 4),
                    Container(
                      height: clampD(barArea * it.steps / maxV, 4.0, barArea),
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: it.steps >= it.goal
                            ? cs.primary
                            : cs.primary.withOpacity(0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(it.label, style: tt.labelSmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.unit});

  final IconData icon;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(
      children: [
        Icon(icon, size: 22),
        const SizedBox(height: 2),
        Text(value, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        Text(unit, style: tt.labelSmall),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.color,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: color,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
            if (actionLabel != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ),
      ),
    );
  }
}


// ===== screens/history_screen.dart =====
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _month = DateTime(n.year, n.month);
  }

  void _shift(int delta) =>
      setState(() => _month = DateTime(_month.year, _month.month + delta));

  bool get _isCurrentMonth {
    final n = DateTime.now();
    return _month.year == n.year && _month.month == n.month;
  }

  String _encouragement(AppState s) {
    final streak = s.streak;
    if (s.fullDaysCount == 0) {
      return 'أول يوم تخلّص فيه كل مهامك هيبدأ السلسلة. ابدأ النهارده! 💪';
    }
    if (streak == 0) {
      return 'السلسلة وقفت، بس مفيش مشكلة — ابدأ من جديد النهارده وارجع أقوى! 🔄';
    }
    if (streak >= 30) return 'أسطورة! $streak يوم متواصل 👑';
    if (streak >= 7) return 'شغل عالي! $streak أيام متواصلة، كمّل 🔥';
    return 'ممتاز، ${daysText(streak)} متواصلة. كمّل عشان توصل للأسبوع! ⚡';
  }

  void _showDay(BuildContext context, DateTime day) {
    final s = widget.state;
    final key = dateKey(day);
    final rec = s.days[key];
    final runs = s.runsOn(key);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final doneTasks = <TaskItem>[];
    if (rec != null) {
      for (final id in rec.done) {
        final t = s.taskById(id);
        if (t != null) doneTasks.add(t);
      }
    }
    final missing = <TaskItem>[];
    final isToday = key == s.todayKey;
    if (isToday) {
      for (final t in s.activeTasks) {
        if (!(rec?.done.contains(t.id) ?? false)) missing.add(t);
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(DateFormat('EEEE d MMMM yyyy', 'ar').format(day),
                style: tt.titleLarge),
            const SizedBox(height: 12),
            if (rec == null || (rec.isEmpty && runs.isEmpty))
              Text('مفيش نشاط مسجل في اليوم ده.',
                  style: tt.bodyMedium?.copyWith(color: cs.outline)),
            if (rec != null && rec.rest)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bedtime),
                title: Text('يوم راحة'),
                subtitle: Text('السلسلة كانت محفوظة'),
              ),
            if (rec != null && rec.water > 0)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.water_drop),
                title: Text('${rec.water} كوب ماء'),
                subtitle: Text('≈ ${(rec.water * 0.25).toStringAsFixed(2)} لتر'),
              ),
            if (rec != null && rec.steps > 0)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(rec.goalReached ? Icons.emoji_events : Icons.directions_walk,
                    color: rec.goalReached ? Colors.amber.shade700 : null),
                title: Text('${fmtInt(rec.steps)} خطوة'),
                subtitle: Text(rec.goalReached
                    ? 'حققت هدف ${fmtInt(rec.goal)} 🏅'
                    : 'الهدف كان ${fmtInt(rec.goal)}'),
              ),
            if (doneTasks.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('مهام نفّذتها (${doneTasks.length})', style: tt.titleMedium),
              for (final t in doneTasks)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.check_circle, color: cs.primary),
                  title: Text(t.title),
                ),
            ],
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('لسه ناقص', style: tt.titleMedium),
              for (final t in missing)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.radio_button_unchecked, color: cs.outline),
                  title: Text(t.title),
                ),
            ],
            if (runs.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('جلسات الجري/المشي', style: tt.titleMedium),
              for (final r in runs)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.directions_run),
                  title: Text(
                      '${fmtDuration(r.seconds)} • ${r.km.toStringAsFixed(2)} كم'),
                  subtitle: Text('${fmtInt(r.steps)} خطوة • ${r.kcal} سعرة'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final first = DateTime(_month.year, _month.month, 1);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    // الأسبوع يبدأ من السبت: السبت=0 ... الجمعة=6
    final offset = (first.weekday + 1) % 7;
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);

    var monthFull = 0;
    for (var d = 1; d <= daysInMonth; d++) {
      if (s.isFullDay(dateKey(DateTime(_month.year, _month.month, d)))) {
        monthFull++;
      }
    }

    const weekdays = ['س', 'ح', 'ن', 'ث', 'ر', 'خ', 'ج'];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('السجل', style: tt.headlineSmall),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
                child: _StatCard(
                    emoji: '🔥',
                    value: '${s.streak}',
                    label: 'السلسلة الحالية')),
            const SizedBox(width: 8),
            Expanded(
                child: _StatCard(
                    emoji: '🏆', value: '${s.bestStreak}', label: 'أفضل سلسلة')),
            const SizedBox(width: 8),
            Expanded(
                child: _StatCard(
                    emoji: '✅', value: '${s.fullDaysCount}', label: 'أيام كاملة')),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          color: cs.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(_encouragement(s), style: tt.bodyLarge),
          ),
        ),
        const SizedBox(height: 12),
        _WeekCard(summary: s.lastSevenDays()),
        const SizedBox(height: 16),
        Text('الشارات', style: tt.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final b in kBadges)
                _BadgeTile(badge: b, earned: s.bestStreak >= b.days),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            IconButton(
              tooltip: 'الشهر السابق',
              onPressed: () => _shift(-1),
              icon: const Icon(Icons.chevron_right),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(DateFormat('MMMM yyyy', 'ar').format(_month),
                      style: tt.titleMedium),
                  Text('$monthFull يوم كامل هذا الشهر',
                      style: tt.bodySmall?.copyWith(color: cs.outline)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'الشهر التالي',
              onPressed: _isCurrentMonth ? null : () => _shift(1),
              icon: const Icon(Icons.chevron_left),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final w in weekdays)
              Expanded(
                child: Center(
                  child: Text(w,
                      style: tt.labelMedium?.copyWith(color: cs.outline)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (var i = 0; i < offset; i++) const SizedBox.shrink(),
            for (var d = 1; d <= daysInMonth; d++)
              _DayCell(
                day: DateTime(_month.year, _month.month, d),
                rec: s.days[dateKey(DateTime(_month.year, _month.month, d))],
                isToday: DateTime(_month.year, _month.month, d) == todayOnly,
                isFuture: DateTime(_month.year, _month.month, d)
                    .isAfter(todayOnly),
                onTap: () => _showDay(
                    context, DateTime(_month.year, _month.month, d)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _Legend(color: cs.primary, text: 'كل المهام'),
            _Legend(color: cs.primary.withOpacity(0.35), text: 'جزء من المهام'),
            _Legend(color: cs.tertiary, text: 'يوم راحة'),
            const _Legend(color: Colors.amber, text: 'هدف الخطوات'),
          ],
        ),
        const SizedBox(height: 16),
        _WeightCard(state: s),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: cs.surfaceVariant,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _MiniStat(label: 'إجمالي الخطوات', value: fmtInt(s.totalSteps)),
                _MiniStat(label: 'أيام حققت الهدف', value: '${s.goalDaysCount}'),
                _MiniStat(label: 'جلسات الجري', value: '${s.runs.length}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.rec,
    required this.isToday,
    required this.isFuture,
    required this.onTap,
  });

  final DateTime day;
  final DayRecord? rec;
  final bool isToday;
  final bool isFuture;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final full = rec?.tasksComplete ?? false;
    final rest = !full && (rec?.rest ?? false);
    final partial = !full && !rest && (rec?.done.isNotEmpty ?? false);
    final goal = rec?.goalReached ?? false;

    Color? bg;
    Color fg = isFuture ? cs.outlineVariant : cs.onSurface;
    if (full) {
      bg = cs.primary;
      fg = cs.onPrimary;
    } else if (rest) {
      bg = cs.tertiaryContainer;
      fg = cs.onTertiaryContainer;
    } else if (partial) {
      bg = cs.primary.withOpacity(0.35);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: isFuture ? null : onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: isToday ? Border.all(color: cs.primary, width: 2) : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (full)
                  Icon(Icons.check, size: 14, color: fg)
                else if (rest)
                  Icon(Icons.bedtime, size: 14, color: fg)
                else
                  const SizedBox(height: 14),
                Text('${day.day}', style: TextStyle(color: fg, fontSize: 13)),
              ],
            ),
            if (goal)
              const Positioned(
                top: 2,
                right: 2,
                child: Icon(Icons.star, size: 12, color: Colors.amber),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.emoji, required this.value, required this.label});

  final String emoji;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: cs.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            Text(value,
                style: tt.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            Text(label, style: tt.labelSmall, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.badge, required this.earned});

  final StreakBadge badge;
  final bool earned;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      width: 92,
      margin: const EdgeInsetsDirectional.only(end: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: earned ? cs.primaryContainer : cs.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Opacity(
            opacity: earned ? 1 : 0.3,
            child: Text(badge.emoji, style: const TextStyle(fontSize: 28)),
          ),
          const SizedBox(height: 4),
          Text(badge.title,
              style: tt.labelSmall,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(value, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        Text(label, style: tt.labelSmall, textAlign: TextAlign.center),
      ],
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.summary});

  final WeekSummary summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final avg = summary.steps ~/ 7;
    return Card(
      elevation: 0,
      color: cs.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ملخص آخر 7 أيام', style: tt.titleSmall),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _MiniStat(label: 'أيام كاملة', value: '${summary.fullDays}/7'),
                _MiniStat(label: 'متوسط الخطوات', value: fmtInt(avg)),
                _MiniStat(label: 'أيام الهدف', value: '${summary.goalDays}'),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _MiniStat(label: 'جلسات جري', value: '${summary.runCount}'),
                _MiniStat(
                    label: 'مسافة الجري', value: '${summary.km.toStringAsFixed(1)} كم'),
                _MiniStat(label: 'أيام راحة', value: '${summary.restDays}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WeightCard extends StatelessWidget {
  const _WeightCard({required this.state});

  final AppState state;

  Future<void> _add(BuildContext context) async {
    final c = TextEditingController(
        text: state.latestWeight?.toStringAsFixed(1) ?? '');
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('وزن النهارده'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'كجم'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, double.tryParse(c.text.trim().replaceAll(',', '.'))),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (v != null) await state.addWeight(v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final latest = state.latestWeight;
    final change = state.weightChange;
    final recent = state.weights.reversed.take(5).toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('⚖️ الوزن', style: tt.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('تسجيل'),
                ),
              ],
            ),
            if (latest == null)
              Text('سجّل وزنك مرة في الأسبوع (صباحاً على الريق) وتابع تقدمك.',
                  style: tt.bodySmall?.copyWith(color: cs.outline))
            else ...[
              Text('${latest.toStringAsFixed(1)} كجم',
                  style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              if (change != null)
                Text(
                  change == 0
                      ? 'ثابت منذ أول قياس'
                      : '${change > 0 ? '+' : ''}${change.toStringAsFixed(1)} كجم منذ أول قياس',
                  style: tt.bodySmall?.copyWith(color: cs.outline),
                ),
              const SizedBox(height: 8),
              for (final w in recent)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Text(w.key, style: tt.bodySmall),
                      const Spacer(),
                      Text('${w.kg.toStringAsFixed(1)} كجم', style: tt.bodySmall),
                      InkWell(
                        onTap: () => state.removeWeight(w.key),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}


// ===== screens/settings_screen.dart =====
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  void _snack(BuildContext context, String msg) {
    final m = ScaffoldMessenger.of(context);
    m.clearSnackBars();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _export(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: state.exportJson()));
    if (context.mounted) {
      _snack(context, 'تم نسخ النسخة الاحتياطية. الصقها في ملاحظة أو رسالة لنفسك.');
    }
  }

  Future<void> _import(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!context.mounted) return;
    if (text.isEmpty) {
      _snack(context, 'الحافظة فاضية. انسخ النسخة الاحتياطية الأول.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استعادة نسخة احتياطية؟'),
        content: const Text('هيتم استبدال كل بياناتك الحالية بالنسخة الموجودة في الحافظة.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('استعادة')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await state.importJson(text);
    if (context.mounted) {
      _snack(context,
          done ? 'تمت الاستعادة بنجاح ✅' : 'النص ده مش نسخة احتياطية صالحة.');
    }
  }

  Future<void> _reset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مسح كل البيانات؟'),
        content: const Text('هيتم حذف المهام والسجل والجلسات والأوزان نهائياً. الأفضل تاخد نسخة احتياطية الأول.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('مسح')),
        ],
      ),
    );
    if (ok == true) {
      await state.resetAll();
      if (context.mounted) _snack(context, 'تم مسح البيانات.');
    }
  }

  Future<void> _editNumber(
    BuildContext context, {
    required String title,
    required String unit,
    required double initial,
    required void Function(double) onSave,
  }) async {
    final c = TextEditingController(
        text: initial == initial.roundToDouble()
            ? initial.round().toString()
            : initial.toStringAsFixed(1));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(suffixText: unit),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, double.tryParse(c.text.trim().replaceAll(',', '.'))),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (v != null) onSave(v);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final tt = Theme.of(context).textTheme;
        final cs = Theme.of(context).colorScheme;
        final p = state.profile;

        Widget section(String title) => Padding(
              padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
              child: Text(title,
                  style: tt.titleSmall?.copyWith(color: cs.primary)),
            );

        return Scaffold(
          appBar: AppBar(title: const Text('الإعدادات')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              section('المظهر'),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('تلقائي')),
                  ButtonSegment(value: ThemeMode.light, label: Text('فاتح')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('داكن')),
                ],
                selected: {state.themeMode},
                onSelectionChanged: (s) => state.setThemeMode(s.first),
              ),
              section('مستواك التدريبي'),
              SegmentedButton<Level>(
                segments: [
                  for (final l in Level.values)
                    ButtonSegment(value: l, label: Text(l.label)),
                ],
                selected: {state.level},
                onSelectionChanged: (s) => state.setLevel(s.first),
              ),
              const SizedBox(height: 6),
              Text(
                switch (state.level) {
                  Level.beginner => '3 أيام Full Body أسبوعياً (سبت/اثنين/أربعاء).',
                  Level.intermediate => '4 أيام: علوي/سفلي (سبت، أحد، ثلاثاء، أربعاء).',
                  Level.pro => '6 أيام Push / Pull / Legs مع يوم راحة (الجمعة).',
                },
                style: tt.bodySmall?.copyWith(color: cs.outline),
              ),
              section('بياناتك (لحساب المسافة والسعرات)'),
              Card(
                elevation: 0,
                color: cs.surfaceVariant,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          const Expanded(child: Text('الجنس')),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: true, label: Text('ذكر')),
                              ButtonSegment(value: false, label: Text('أنثى')),
                            ],
                            selected: {p.male},
                            onSelectionChanged: (s) =>
                                state.updateProfile(male: s.first),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      title: const Text('الطول'),
                      subtitle: Text('طول الخطوة المقدّر ${p.strideM.toStringAsFixed(2)} م'),
                      trailing: Text('${p.heightCm.round()} سم'),
                      onTap: () => _editNumber(
                        context,
                        title: 'الطول',
                        unit: 'سم',
                        initial: p.heightCm,
                        onSave: (v) => state.updateProfile(heightCm: v),
                      ),
                    ),
                    ListTile(
                      title: const Text('الوزن'),
                      subtitle: const Text('بيتسجل في سجل الوزن'),
                      trailing: Text('${p.weightKg.toStringAsFixed(1)} كجم'),
                      onTap: () => _editNumber(
                        context,
                        title: 'الوزن الحالي',
                        unit: 'كجم',
                        initial: p.weightKg,
                        onSave: (v) => state.addWeight(v),
                      ),
                    ),
                  ],
                ),
              ),
              section('الأهداف'),
              Card(
                elevation: 0,
                color: cs.surfaceVariant,
                child: ListTile(
                  title: const Text('هدف الماء اليومي'),
                  subtitle: Text(
                      '${state.waterGoal} أكواب ≈ ${(state.waterGoal * 0.25).toStringAsFixed(1)} لتر'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => state.setWaterGoal(state.waterGoal - 1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => state.setWaterGoal(state.waterGoal + 1),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text('هدف الخطوات بتعدّله من تبويب "الخطوات".',
                  style: tt.bodySmall?.copyWith(color: cs.outline)),
              section('البيانات'),
              Card(
                elevation: 0,
                color: cs.surfaceVariant,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.copy_all),
                      title: const Text('نسخ نسخة احتياطية'),
                      subtitle: const Text('تنسخ كل بياناتك للحافظة'),
                      onTap: () => _export(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.paste),
                      title: const Text('استعادة من الحافظة'),
                      onTap: () => _import(context),
                    ),
                    ListTile(
                      leading: Icon(Icons.delete_forever, color: cs.error),
                      title: Text('مسح كل البيانات',
                          style: TextStyle(color: cs.error)),
                      onTap: () => _reset(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'طول الخطوة والسعرات تقديرية وبتعتمد على طولك ووزنك، فخد الأرقام كدليل مش قياس دقيق.',
                style: tt.bodySmall?.copyWith(color: cs.outline),
              ),
            ],
          ),
        );
      },
    );
  }
}


// ===== screens/guide_screen.dart =====
class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('الدليل', style: tt.headlineSmall),
        const SizedBox(height: 12),
        const _CalorieCalculator(),
        const SizedBox(height: 8),
        const _Section(
          icon: '🟢',
          title: 'مبتدئ (أول 3 شهور)',
          body: 'الهدف: تعوّد الجسم + تعلّم الفورم.\n'
              'الجدول: 3 أيام أسبوعياً (سبت/اثنين/أربعاء) مع يوم راحة بين كل تمرين.\n\n'
              'Full Body:\n'
              '• ضغط: 3 × 8-12\n'
              '• سكوات بوزن الجسم: 3 × 12-15\n'
              '• سحب/عقلة مساعدة: 3 × 5-8\n'
              '• بلانك: 3 × 20-30 ثانية\n'
              '• لانجز: 3 × 10 لكل رجل\n'
              '• جسر المؤخرة: 3 × 15\n\n'
              'قواعد: أول أسبوعين وزن الجسم فقط • ركّز على الفورم • ألم حاد = وقف فوراً • '
              'زوّد 2.5% بس كل أسبوع • راحة 60-90 ثانية بين المجموعات.',
        ),
        const _Section(
          icon: '🟡',
          title: 'متوسط (3-12 شهر)',
          body: '4 أيام أسبوعياً — تقسيم علوي/سفلي:\n'
              '• يوم 1: علوي (صدر + ظهر + كتف + ذراع)\n'
              '• يوم 2: سفلي (فخذ + سمانة + بطن)\n'
              '• يوم 3: راحة\n'
              '• يوم 4: علوي  • يوم 5: سفلي  • يوم 6-7: راحة\n\n'
              'أساسيات: بنش/دامبل برس، عقلة، تجديف بار، سكوات بار، ديدلفت (بحذر)، ضغط كتف.',
        ),
        const _Section(
          icon: '🔴',
          title: 'محترف (أكثر من سنة)',
          body: 'Push / Pull / Legs — 5-6 أيام، وتكرار الدورة مرتين أسبوعياً.\n\n'
              '• Progressive Overload: زوّد الوزن أو التكرارات كل أسبوع\n'
              '• 4 أسابيع بناء + أسبوع Deload خفيف\n'
              '• سجّل كل تمرين (وزن × تكرار × مجموعة)\n'
              '• ركّز على العضلات الضعيفة\n'
              '• راحة 90-120 ثانية للمجموعات الثقيلة',
        ),
        const _Section(
          icon: '🧘',
          title: 'التسخين والتمدد',
          body: 'قبل التمرين (5 دقائق ديناميكي): دوران الكتفين والحوض، High Knees، Jumping Jacks. '
              'تجنّب التمدد الثابت الطويل قبل التمرين.\n\n'
              'بعد التمرين (10 دقائق ثابت):\n'
              '• Cobra: 30 ث\n• Cat-Cow: 10 تكرارات\n• خلف الفخذ: 30 ث لكل رجل\n'
              '• أمام الفخذ: 30 ث لكل رجل\n• Child\'s Pose: 45 ث\n'
              '• Shoulder Dislocates: 10 تكرارات\n• السمانة: 30 ث',
        ),
        const _Section(
          icon: '🍗',
          title: 'التغذية',
          body: 'البروتين: 1.6-2.2 جم × وزنك بالكيلو • الكارب: 40-50% • الدهون: 20-30%.\n\n'
              '• قبل التمرين (ساعة-ساعتين): كارب + بروتين خفيف (موزة + زبادي)\n'
              '• بعد التمرين (خلال ساعة): بروتين + كارب (فراخ + أرز)\n'
              '• قبل النوم: جبن قريش أو زبادي يوناني\n\n'
              'بروتين: فراخ، سمك، بيض، لحم، عدس، فول، جبن قريش.\n'
              'كارب: شوفان، أرز بني، بطاطا، خبز أسمر.\n'
              'دهون: زيت زيتون، مكسرات، أفوكادو، سمك دهني.',
        ),
        const _Section(
          icon: '🥇',
          title: 'الأساسيات الخمسة',
          body: '1. تمرين منتظم (3-5 أيام)\n2. أكل كافي (سعرات + بروتين)\n'
              '3. نوم 7-9 ساعات\n4. ماء 2-3 لتر يومياً\n'
              '5. استمرارية — 6 شهور منتظمة أحسن من سنة متقطعة.\n\n'
              'بتبطّل التقدم: السهر، البروتين القليل، الإفراط في التمرين، تغيير التمرين كل أسبوع، '
              'وإهمال التسخين والتمدد.',
        ),
        const _Section(
          icon: '📏',
          title: 'الطول — كلام واقعي',
          body: 'الطول جيني بنسبة ~80%. لو لسه في سن النمو: نوم مبكر وكافي، بروتين + كالسيوم + '
              'فيتامين D، سباحة وكرة سلة ونط الحبل، وقوام سليم.\n\n'
              'لو عدّيت سن النمو: ركّز على الوقفة الصحيحة وتقوية عضلات الظهر. '
              'وابعد عن أي مكملات "زيادة طول" — غير مثبتة.',
        ),
        const SizedBox(height: 8),
        Text(
          'هذه معلومات عامة للتوعية وليست بديلاً عن استشارة طبيب أو مدرب مختص.',
          style: tt.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.body});

  final String icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Text(icon, style: const TextStyle(fontSize: 22)),
        title: Text(title),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(body, style: const TextStyle(height: 1.6))],
      ),
    );
  }
}

class _CalorieCalculator extends StatefulWidget {
  const _CalorieCalculator();

  @override
  State<_CalorieCalculator> createState() => _CalorieCalculatorState();
}

class _CalorieCalculatorState extends State<_CalorieCalculator> {
  final _age = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  bool _male = true;
  double _activity = 1.55;
  int _goal = 0; // -1 إنقاص، 0 ثبات، 1 بناء

  static final _activities = <double, String>{
    1.2: 'خامل (مكتبي)',
    1.375: 'خفيف (1-3 أيام)',
    1.55: 'متوسط (3-5 أيام)',
    1.725: 'نشيط (6-7 أيام)',
    1.9: 'رياضي محترف',
  };

  @override
  void dispose() {
    _age.dispose();
    _weight.dispose();
    _height.dispose();
    super.dispose();
  }

  Widget? _result(BuildContext context) {
    final age = double.tryParse(_age.text.trim());
    final w = double.tryParse(_weight.text.trim());
    final h = double.tryParse(_height.text.trim());
    if (age == null || w == null || h == null || age <= 0 || w <= 0 || h <= 0) {
      return null;
    }
    final bmr = 10 * w + 6.25 * h - 5 * age + (_male ? 5 : -161);
    final tdee = bmr * _activity;
    final target = tdee + (_goal * 400);
    final protein = (w * 1.8).round();
    final fat = (target * 0.25 / 9).round();
    final carbs = ((target - protein * 4 - fat * 9) / 4).round();
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${target.round()} سعرة يومياً', style: tt.titleLarge),
          const SizedBox(height: 4),
          Text('BMR: ${bmr.round()} • الثبات: ${tdee.round()}'),
          Text('بروتين ~$protein جم • كارب ~$carbs جم • دهون ~$fat جم'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🧮 حاسبة السعرات', style: tt.titleMedium),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('ذكر')),
                ButtonSegment(value: false, label: Text('أنثى')),
              ],
              selected: {_male},
              onSelectionChanged: (s) => setState(() => _male = s.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final f in [
                  (_age, 'السن'),
                  (_weight, 'الوزن (كجم)'),
                  (_height, 'الطول (سم)'),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: TextField(
                        controller: f.$1,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: f.$2,
                          filled: true,
                          fillColor: cs.surface,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<double>(
              value: _activity,
              decoration: InputDecoration(
                labelText: 'مستوى النشاط',
                filled: true,
                fillColor: cs.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              items: [
                for (final e in _activities.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _activity = v ?? _activity),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: -1, label: Text('إنقاص دهون')),
                ButtonSegment(value: 0, label: Text('ثبات')),
                ButtonSegment(value: 1, label: Text('بناء عضل')),
              ],
              selected: {_goal},
              onSelectionChanged: (s) => setState(() => _goal = s.first),
            ),
            if (_result(context) != null) _result(context)!,
          ],
        ),
      ),
    );
  }
}


// ===== main.dart =====
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs)..load();
  runApp(FitApp(state: state));
  // نطلب الصلاحية ونبدأ العد بعد ظهور الواجهة.
  state.initSteps();
}

class FitApp extends StatelessWidget {
  const FitApp({super.key, required this.state});

  final AppState state;

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A67E),
          brightness: b,
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'لياقتي',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar', 'EG'),
        supportedLocales: const [Locale('ar', 'EG'), Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: state.themeMode,
        home: HomeShell(state: state),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    switch (s) {
      case AppLifecycleState.resumed:
        widget.state.onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        widget.state.flush();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final pages = <Widget>[
          TodayScreen(state: state),
          StepsScreen(state: state),
          HistoryScreen(state: state),
          const GuideScreen(),
        ];
        return Scaffold(
          body: SafeArea(
            child: IndexedStack(index: _index, children: pages),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.checklist_rtl_outlined),
                selectedIcon: Icon(Icons.checklist_rtl),
                label: 'اليوم',
              ),
              NavigationDestination(
                icon: Icon(Icons.directions_run_outlined),
                selectedIcon: Icon(Icons.directions_run),
                label: 'الخطوات',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: 'السجل',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book),
                label: 'الدليل',
              ),
            ],
          ),
        );
      },
    );
  }
}