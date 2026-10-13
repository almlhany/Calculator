import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const AlarmApp());

// ═══════════ النغمات (تُولَّد بالكود، لا حاجة لملفات) ═══════════
// كل نوتة: [التردد بالهرتز، المدة بالميلي ثانية] ، التردد 0 = صمت
// لإضافة نغمة جديدة أضف سطراً جديداً هنا
class Ringtone {
  final String id, name;
  final List<List<num>> notes;
  const Ringtone(this.id, this.name, this.notes);
}

const presets = [
  Ringtone('classic', 'كلاسيكي', [[880, 150], [0, 100], [880, 150], [0, 100], [880, 150], [0, 700]]),
  Ringtone('gentle', 'هادئ', [[523, 500], [659, 500], [784, 800], [0, 700]]),
  Ringtone('digital', 'رقمي', [[1200, 80], [0, 60], [1200, 80], [0, 60], [1600, 140], [0, 600]]),
  Ringtone('rooster', 'متصاعد', [[440, 200], [554, 200], [659, 200], [880, 400], [0, 600]]),
];

Uint8List buildWav(List<List<num>> seq, {int rate = 22050}) {
  final samples = <int>[];
  for (final n in seq) {
    final f = n[0].toDouble();
    final len = (rate * n[1] / 1000).round();
    for (var i = 0; i < len; i++) {
      double v = 0;
      if (f > 0) {
        final env = math.min(1.0, math.min(i, len - i) / (rate * 0.01));
        v = math.sin(2 * math.pi * f * i / rate) * env * 0.6;
      }
      samples.add((v * 32767).round());
    }
  }
  final d = ByteData(44 + samples.length * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      d.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  d.setUint32(4, 36 + samples.length * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  str(36, 'data');
  d.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    d.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return d.buffer.asUint8List();
}

const dayNames = ['الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];

String fmtTime(int h, int m) {
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'ص' : 'م'}';
}

// ═══════════ النموذج ═══════════
class Alarm {
  String id;
  int hour, minute;
  String label;
  bool enabled;
  Set<int> days; // 1=الإثنين … 7=الأحد ، فارغ = مرة واحدة
  String ringtone; // معرّف نغمة جاهزة، أو url:الرابط
  bool snoozeEnabled;
  int snoozeMinutes, maxSnoozes;

  Alarm({
    required this.id,
    this.hour = 7,
    this.minute = 0,
    this.label = '',
    this.enabled = true,
    Set<int>? days,
    this.ringtone = 'classic',
    this.snoozeEnabled = true,
    this.snoozeMinutes = 5,
    this.maxSnoozes = 3,
  }) : days = days ?? {};

  bool get isDaily => days.length == 7;
  Alarm copy() => Alarm.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'label': label,
        'enabled': enabled,
        'days': days.toList(),
        'ringtone': ringtone,
        'snoozeEnabled': snoozeEnabled,
        'snoozeMinutes': snoozeMinutes,
        'maxSnoozes': maxSnoozes,
      };

  factory Alarm.fromJson(Map<String, dynamic> j) => Alarm(
        id: j['id'],
        hour: j['hour'],
        minute: j['minute'],
        label: j['label'] ?? '',
        enabled: j['enabled'] ?? true,
        days: (j['days'] as List).cast<int>().toSet(),
        ringtone: j['ringtone'] ?? 'classic',
        snoozeEnabled: j['snoozeEnabled'] ?? true,
        snoozeMinutes: j['snoozeMinutes'] ?? 5,
        maxSnoozes: j['maxSnoozes'] ?? 3,
      );

  String get repeatText {
    if (days.isEmpty) return 'مرة واحدة';
    if (isDaily) return 'يومياً';
    final s = days.toList()..sort();
    return s.map((d) => dayNames[d - 1]).join('، ');
  }
}

// ═══════════ المتحكم ═══════════
class AlarmController extends ChangeNotifier {
  final List<Alarm> alarms = [];
  final AudioPlayer _player = AudioPlayer();
  final Map<String, DateTime> _snoozedUntil = {};
  final Map<String, int> _snoozeCount = {};
  final Map<String, Uint8List> _tones = {};

  SharedPreferences? _prefs;
  Timer? _ticker, _autoSnoozeTimer, _fadeTimer;
  String? _lastFired;

  DateTime now = DateTime.now();
  Alarm? ringing;
  int nightMode = 0; // 0 تلقائي، 1 دائماً ليلي، 2 نهاري

  static const autoSnoozeAfter = Duration(seconds: 60);

  bool get isNight => nightMode == 1 || (nightMode == 0 && (now.hour >= 21 || now.hour < 6));
  int get ringSnoozeCount => ringing == null ? 0 : (_snoozeCount[ringing!.id] ?? 0);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    nightMode = _prefs!.getInt('nightMode') ?? 0;
    final raw = _prefs!.getString('alarms');
    if (raw != null) {
      alarms.addAll((jsonDecode(raw) as List).map((e) => Alarm.fromJson(e)));
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      _check();
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _autoSnoozeTimer?.cancel();
    _fadeTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _save() {
    _prefs?.setString('alarms', jsonEncode(alarms.map((a) => a.toJson()).toList()));
    _prefs?.setInt('nightMode', nightMode);
  }

  void cycleNightMode() {
    nightMode = (nightMode + 1) % 3;
    _save();
    notifyListeners();
  }

  void upsert(Alarm a) {
    final i = alarms.indexWhere((x) => x.id == a.id);
    i == -1 ? alarms.add(a) : alarms[i] = a;
    alarms.sort((x, y) => (x.hour * 60 + x.minute).compareTo(y.hour * 60 + y.minute));
    _snoozedUntil.remove(a.id);
    _save();
    notifyListeners();
  }

  void remove(Alarm a) {
    alarms.removeWhere((x) => x.id == a.id);
    _snoozedUntil.remove(a.id);
    _save();
    notifyListeners();
  }

  void toggle(Alarm a, bool v) {
    a.enabled = v;
    _snoozedUntil.remove(a.id);
    _save();
    notifyListeners();
  }

  // فحص المواقيت كل ثانية
  void _check() {
    if (ringing != null) return;
    for (final a in alarms.where((a) => a.enabled)) {
      final su = _snoozedUntil[a.id];
      if (su != null) {
        if (!now.isBefore(su)) {
          _snoozedUntil.remove(a.id);
          _ring(a);
          return;
        }
        continue;
      }
      final key = '${a.id}-${now.year}${now.month}${now.day}${now.hour}${now.minute}';
      final dayOk = a.days.isEmpty || a.days.contains(now.weekday);
      if (a.hour == now.hour && a.minute == now.minute && dayOk && _lastFired != key) {
        _lastFired = key;
        _snoozeCount[a.id] = 0;
        _ring(a);
        return;
      }
    }
  }

  void _ring(Alarm a) {
    ringing = a;
    _play(a.ringtone, fadeIn: true);
    _autoSnoozeTimer?.cancel();
    _autoSnoozeTimer = Timer(autoSnoozeAfter, () => snooze());
    notifyListeners();
  }

  bool get canSnooze {
    final a = ringing;
    return a != null && a.snoozeEnabled && (_snoozeCount[a.id] ?? 0) < a.maxSnoozes;
  }

  // غفوة يدوية، أو تلقائية بعد دقيقة بلا تفاعل
  void snooze() {
    final a = ringing;
    if (a == null) return;
    _stopSound();
    if (canSnooze) {
      _snoozeCount[a.id] = (_snoozeCount[a.id] ?? 0) + 1;
      _snoozedUntil[a.id] = DateTime.now().add(Duration(minutes: a.snoozeMinutes));
    } else {
      _finish(a);
    }
    ringing = null;
    notifyListeners();
  }

  void dismiss() {
    final a = ringing;
    if (a == null) return;
    _stopSound();
    _snoozedUntil.remove(a.id);
    _finish(a);
    ringing = null;
    notifyListeners();
  }

  void _finish(Alarm a) {
    if (a.days.isEmpty) a.enabled = false;
    _save();
  }

  // الصوت
  Source _source(String id) {
    if (id.startsWith('url:')) return UrlSource(id.substring(4));
    final r = presets.firstWhere((r) => r.id == id, orElse: () => presets.first);
    final bytes = _tones.putIfAbsent(r.id, () => buildWav(r.notes));
    return BytesSource(bytes, mimeType: 'audio/wav');
  }

  Future<void> _play(String id, {bool fadeIn = false}) async {
    try {
      _fadeTimer?.cancel();
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(fadeIn ? 0.1 : 1.0);
      await _player.play(_source(id));
      if (fadeIn) {
        // رفع الصوت تدريجياً لإيقاظ لطيف
        double v = 0.1;
        _fadeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
          v = (v + 0.1).clamp(0.0, 1.0);
          _player.setVolume(v);
          if (v >= 1.0) t.cancel();
        });
      }
    } catch (e) {
      debugPrint('Audio error: $e');
    }
  }

  void _stopSound() {
    _autoSnoozeTimer?.cancel();
    _fadeTimer?.cancel();
    _player.stop();
  }

  void preview(String id) => _play(id);
  void stopPreview() => _player.stop();

  String ringtoneName(String id) {
    if (id.startsWith('url:')) return 'نغمة مخصصة';
    return presets.firstWhere((r) => r.id == id, orElse: () => presets.first).name;
  }

  DateTime? get nextAlarmTime {
    DateTime? best;
    for (final a in alarms.where((a) => a.enabled)) {
      final su = _snoozedUntil[a.id];
      if (su != null && (best == null || su.isBefore(best))) best = su;
      for (var d = 0; d <= 7; d++) {
        final t = DateTime(now.year, now.month, now.day + d, a.hour, a.minute);
        if (!t.isAfter(now)) continue;
        if (a.days.isNotEmpty && !a.days.contains(t.weekday)) continue;
        if (best == null || t.isBefore(best)) best = t;
        break;
      }
    }
    return best;
  }

  String get nextAlarmText {
    final t = nextAlarmTime;
    if (t == null) return 'لا توجد منبهات مفعّلة';
    final diff = t.difference(now);
    final h = diff.inHours, m = diff.inMinutes % 60;
    if (h == 0 && m == 0) return 'سيرنّ المنبه بعد أقل من دقيقة';
    return 'يرنّ المنبه بعد ${h > 0 ? '$h ساعة و' : ''}$m دقيقة';
  }
}

// ═══════════ التطبيق والثيمات ═══════════
class AlarmApp extends StatefulWidget {
  const AlarmApp({super.key});
  @override
  State<AlarmApp> createState() => _AlarmAppState();
}

class _AlarmAppState extends State<AlarmApp> {
  final c = AlarmController();

  @override
  void initState() {
    super.initState();
    c.init();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  ThemeData _theme(bool night) {
    if (night) {
      // ليلي: أسود حقيقي + كهرماني خافت بدل الأبيض الساطع
      const amber = Color(0xFFE59A45);
      return ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: amber, brightness: Brightness.dark)
            .copyWith(primary: amber, surface: Colors.black, onSurface: const Color(0xFFC9B79F)),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, elevation: 0),
      );
    }
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F6E6E)),
      scaffoldBackgroundColor: const Color(0xFFF1F5F6),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'المنبّه',
        theme: _theme(c.isNight),
        builder: (ctx, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: Stack(children: [child!, if (c.ringing != null) RingingOverlay(c: c)]),
        ),
        home: HomePage(c: c),
      ),
    );
  }
}

// ═══════════ الصفحة الرئيسية ═══════════
class HomePage extends StatelessWidget {
  final AlarmController c;
  const HomePage({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final nightIcon = [Icons.brightness_auto, Icons.nightlight_round, Icons.light_mode][c.nightMode];
    final nightTip = ['وضع الليل: تلقائي', 'وضع الليل: دائم', 'وضع الليل: مُعطّل'][c.nightMode];

    return Scaffold(
      appBar: AppBar(
        title: const Text('المنبّه'),
        actions: [
          IconButton(
            tooltip: 'ساعة السرير',
            icon: const Icon(Icons.bedtime_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NightClockPage(c: c))),
          ),
          IconButton(tooltip: nightTip, icon: Icon(nightIcon), onPressed: c.cycleNightMode),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_alarm),
        label: const Text('منبه جديد'),
        onPressed: () => openEditor(context, c, null),
      ),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 860;
        final clock = ClockPanel(c: c);
        final list = AlarmList(c: c);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 5, child: clock),
                      const SizedBox(width: 24),
                      Expanded(flex: 6, child: list),
                    ])
                  : Column(children: [clock, const SizedBox(height: 12), Expanded(child: list)]),
            ),
          ),
        );
      }),
    );
  }
}

class ClockPanel extends StatelessWidget {
  final AlarmController c;
  const ClockPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = c.now;
    final hh = (n.hour % 12 == 0 ? 12 : n.hour % 12).toString().padLeft(2, '0');
    final mm = n.minute.toString().padLeft(2, '0');
    final ss = n.second.toString().padLeft(2, '0');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.primary.withOpacity(.35), width: 1.5),
      ),
      child: Column(children: [
        Directionality(
          textDirection: TextDirection.ltr,
          child: FittedBox(
            child: Text('$hh:$mm',
                style: TextStyle(
                    fontSize: 88,
                    fontWeight: FontWeight.w200,
                    letterSpacing: 2,
                    color: cs.primary,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
        Text('$ss ثانية  ${n.hour < 12 ? 'صباحاً' : 'مساءً'}',
            style: TextStyle(color: cs.onSurface.withOpacity(.7))),
        const SizedBox(height: 14),
        Text(c.nextAlarmText, style: Theme.of(context).textTheme.titleMedium),
      ]),
    );
  }
}

class AlarmList extends StatelessWidget {
  final AlarmController c;
  const AlarmList({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    if (c.alarms.isEmpty) {
      return const Center(
          child: Text('لا توجد منبهات بعد.\nاضغط «منبه جديد» لإضافة أول منبه.', textAlign: TextAlign.center));
    }
    final cs = Theme.of(context).colorScheme;
    final night = c.isNight;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: c.alarms.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final a = c.alarms[i];
        return Dismissible(
          key: ValueKey(a.id),
          direction: DismissDirection.startToEnd,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(color: Colors.red.shade800, borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => c.remove(a),
          child: Card(
            elevation: 0,
            color: night ? const Color(0xFF0F0B07) : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => openEditor(context, c, a),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(fmtTime(a.hour, a.minute),
                          style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w300,
                              color: a.enabled ? cs.primary : cs.onSurface.withOpacity(.4))),
                      if (a.label.isNotEmpty) Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${a.repeatText}  •  ${c.ringtoneName(a.ringtone)}',
                          style: TextStyle(fontSize: 12.5, color: cs.onSurface.withOpacity(.65))),
                    ]),
                  ),
                  Switch(value: a.enabled, onChanged: (v) => c.toggle(a, v)),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════ محرر المنبه ═══════════
Future<void> openEditor(BuildContext context, AlarmController c, Alarm? existing) async {
  final draft = existing?.copy() ?? Alarm(id: DateTime.now().microsecondsSinceEpoch.toString());
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => AlarmEditor(c: c, a: draft),
  );
  c.stopPreview();
  if (saved == true) c.upsert(draft..enabled = true);
}

class AlarmEditor extends StatefulWidget {
  final AlarmController c;
  final Alarm a;
  const AlarmEditor({super.key, required this.c, required this.a});
  @override
  State<AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<AlarmEditor> {
  Alarm get a => widget.a;
  AlarmController get c => widget.c;
  late final TextEditingController _label = TextEditingController(text: a.label);
  late final TextEditingController _url =
      TextEditingController(text: a.ringtone.startsWith('url:') ? a.ringtone.substring(4) : '');
  bool _previewing = false;

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: a.hour, minute: a.minute));
    if (t != null) {
      setState(() {
        a.hour = t.hour;
        a.minute = t.minute;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUrl = a.ringtone.startsWith('url:');

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: TextButton(
                onPressed: _pickTime,
                child: Text(fmtTime(a.hour, a.minute),
                    style: TextStyle(fontSize: 56, fontWeight: FontWeight.w200, color: cs.primary)),
              ),
            ),
            TextField(
              controller: _label,
              onChanged