part of 'js_core.dart';

double jTimeClip(num time) => !time.isFinite || time.abs() > 8640000000000000
    ? double.nan
    : time == 0
    ? 0.0
    : time.truncateToDouble() + 0.0;

class JDate extends JObject {
  double time;
  JDate(this.time) {
    prototype = jDatePrototype;
  }
  JDate.prototype() : time = double.nan;
}

final jDatePrototype = JDate.prototype();
const jMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const jWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

JDate jDateReceiver(dynamic value) {
  if (value is! JDate)
    throw JThrown(JError('TypeError', 'Date receiver required'));
  return value;
}

DateTime jDateTime(double time, bool utc) =>
    DateTime.fromMillisecondsSinceEpoch(time.toInt(), isUtc: utc);
String jPad(int value, [int width = 2]) => value.toString().padLeft(width, '0');
String jDateYear(int year) => year >= 0 ? jPad(year, 4) : '-${jPad(-year, 4)}';

double jMakeDate(
  List<double> fields, {
  required bool utc,
  bool adjustYear = false,
}) {
  if (fields.any((v) => !v.isFinite)) return double.nan;
  var values = fields.map((v) => v.truncateToDouble()).toList();
  if (adjustYear && values[0] >= 0 && values[0] <= 99) values[0] += 1900;
  // Normalize months before constructing DateTime and use its overflow rules
  // for days/time; protect the host's integer conversion from huge inputs.
  final year = values[0] + (values[1] / 12).floorToDouble();
  final month = values[1] % 12;
  if (year.abs() > 100000000 || values.skip(2).any((v) => v.abs() > 1e17))
    return double.nan;
  try {
    final date = utc
        ? DateTime.utc(
            year.toInt(),
            month.toInt() + 1,
            values[2].toInt(),
            values[3].toInt(),
            values[4].toInt(),
            values[5].toInt(),
            values[6].toInt(),
          )
        : DateTime(
            year.toInt(),
            month.toInt() + 1,
            values[2].toInt(),
            values[3].toInt(),
            values[4].toInt(),
            values[5].toInt(),
            values[6].toInt(),
          );
    return jTimeClip(date.millisecondsSinceEpoch);
  } on ArgumentError {
    return double.nan;
  }
}

double jDateParse(String source) {
  final match = RegExp(
    r'^([+-][0-9]{6}|[0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{3}))?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?$',
  ).firstMatch(source);
  if (match != null) {
    if (match[1] == '-000000') return double.nan;
    int number(int i, int fallback) => int.parse(match[i] ?? '$fallback');
    final year = number(1, 0), month = number(2, 1), day = number(3, 1);
    final hour = number(4, 0),
        minute = number(5, 0),
        second = number(6, 0),
        ms = number(7, 0);
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 24 ||
        minute > 59 ||
        second > 59 ||
        hour == 24 && (minute != 0 || second != 0 || ms != 0))
      return double.nan;
    final zone = match[8];
    var offset = 0;
    if (zone != null && zone != 'Z') {
      final h = int.parse(zone.substring(1, 3)),
          m = int.parse(zone.substring(4));
      if (h > 23 || m > 59) return double.nan;
      offset = (h * 60 + m) * (zone[0] == '-' ? -1 : 1);
    }
    return jMakeDate([
      year.toDouble(),
      (month - 1).toDouble(),
      day.toDouble(),
      hour.toDouble(),
      (minute - offset).toDouble(),
      second.toDouble(),
      ms.toDouble(),
    ], utc: match[4] == null || zone != null);
  }
  // Round-trip the specified UTC and local string formats (whole seconds).
  var m = RegExp(
    r'^[A-Za-z]{3}, ([0-9]{2}) ([A-Za-z]{3}) (-?[0-9]{4,6}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$',
  ).firstMatch(source);
  if (m != null && jMonths.contains(m[2]))
    return jMakeDate([
      double.parse(m[3]!),
      jMonths.indexOf(m[2]!).toDouble(),
      double.parse(m[1]!),
      double.parse(m[4]!),
      double.parse(m[5]!),
      double.parse(m[6]!),
      0.0,
    ], utc: true);
  m = RegExp(
    r'^[A-Za-z]{3} ([A-Za-z]{3}) ([0-9]{2}) (-?[0-9]{4,6}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT([+-])([0-9]{2})([0-9]{2})(?: \(.*\))?$',
  ).firstMatch(source);
  if (m != null && jMonths.contains(m[1])) {
    final offset =
        (int.parse(m[8]!) * 60 + int.parse(m[9]!)) * (m[7] == '-' ? -1 : 1);
    return jMakeDate([
      double.parse(m[3]!),
      jMonths.indexOf(m[1]!).toDouble(),
      double.parse(m[2]!),
      double.parse(m[4]!),
      double.parse(m[5]!) - offset,
      double.parse(m[6]!),
      0.0,
    ], utc: true);
  }
  return double.nan;
}

String jDateString(JDate value, String format) {
  if (value.time.isNaN) {
    if (format == 'toISOString')
      throw JThrown(JError('RangeError', 'Invalid time value'));
    return 'Invalid Date';
  }
  final d = jDateTime(
    value.time,
    format == 'toISOString' || format == 'toUTCString',
  );
  final time = '${jPad(d.hour)}:${jPad(d.minute)}:${jPad(d.second)}';
  if (format == 'toISOString') {
    final year = d.year >= 0 && d.year <= 9999
        ? jPad(d.year, 4)
        : '${d.year < 0 ? '-' : '+'}${jPad(d.year.abs(), 6)}';
    return '$year-${jPad(d.month)}-${jPad(d.day)}T$time.${jPad(d.millisecond, 3)}Z';
  }
  if (format == 'toUTCString')
    return '${jWeekdays[d.weekday - 1]}, ${jPad(d.day)} ${jMonths[d.month - 1]} ${jDateYear(d.year)} $time GMT';
  final date =
      '${jWeekdays[d.weekday - 1]} ${jMonths[d.month - 1]} ${jPad(d.day)} ${jDateYear(d.year)}';
  final offset = d.timeZoneOffset.inMinutes;
  final clock =
      '$time GMT${offset < 0 ? '-' : '+'}${jPad(offset.abs() ~/ 60)}${jPad(offset.abs() % 60)} (${d.timeZoneName})';
  return format == 'toDateString'
      ? date
      : format == 'toTimeString'
      ? clock
      : '$date $clock';
}

void installJSDates(JScope scope) {
  JDate construct(List<dynamic> a) {
    if (a.isEmpty)
      return JDate(DateTime.now().millisecondsSinceEpoch.toDouble());
    if (a.length == 1) {
      if (a[0] is JDate) return JDate((a[0] as JDate).time);
      final value = jPrimitive(a[0]);
      return JDate(
        value is String ? jDateParse(value) : jTimeClip(jNumber(value)),
      );
    }
    return JDate(
      jMakeDate(
        [
          for (var i = 0; i < 7; i++)
            i < a.length
                ? jNumber(a[i])
                : i == 2
                ? 1.0
                : 0.0,
        ],
        utc: false,
        adjustYear: true,
      ),
    );
  }

  final constructor = JFunction(
    (a, _) => jDateString(construct([]), 'toString'),
    constructWithTarget: jBuiltinAllocator(jDatePrototype, construct),
  );
  constructor.properties.addAll({
    'prototype': jDatePrototype,
    'now': jBuiltin((a) => DateTime.now().millisecondsSinceEpoch.toDouble()),
    'parse': jBuiltin((a) => jDateParse(jString(jArg(a, 0)))),
    'UTC': jBuiltin(
      (a) => jMakeDate(
        [
          for (var i = 0; i < 7; i++)
            i < a.length
                ? jNumber(a[i])
                : i == 0
                ? double.nan
                : i == 2
                ? 1.0
                : 0.0,
        ],
        utc: true,
        adjustYear: true,
      ),
    ),
  });
  jDatePrototype.properties['constructor'] = constructor;
  for (final format in [
    'toISOString',
    'toUTCString',
    'toString',
    'toDateString',
    'toTimeString',
  ]) {
    jDatePrototype.properties[format] = JFunction(
      (a, r) => jDateString(jDateReceiver(r), format),
      constructible: false,
    );
  }
  jDatePrototype.properties['toGMTString'] =
      jDatePrototype.properties['toUTCString'];
  jDatePrototype.properties['toJSON'] = JFunction((a, r) {
    final object = jObject(jRequireCoercible(r)),
        value = jPrimitive(object, hint: 'number');
    if (value is num && !value.isFinite) return null;
    return jInvoke(object, 'toISOString', []);
  }, constructible: false);
  jDatePrototype.symbols[jSymbols['toPrimitive']!] = JFunction((a, r) {
    if (r is! JObject && r is! List)
      throw JThrown(JError('TypeError', 'Date conversion requires an object'));
    final hint = jArg(a, 0);
    if (!['default', 'string', 'number'].contains(hint))
      throw JThrown(JError('TypeError', 'Invalid conversion hint'));
    for (final key
        in hint == 'number'
            ? ['valueOf', 'toString']
            : ['toString', 'valueOf']) {
      final fn = jGet(r, key);
      if (fn is JFunction) {
        final result = jCall(fn, [], receiver: r);
        if (result is! JObject && result is! List) return result;
      }
    }
    throw JThrown(JError('TypeError', 'Cannot convert Date to primitive'));
  }, constructible: false);
  jDatePrototype.properties['valueOf'] = JFunction(
    (a, r) => jDateReceiver(r).time,
    constructible: false,
  );
  jDatePrototype.properties['getTime'] = JFunction(
    (a, r) => jDateReceiver(r).time,
    constructible: false,
  );
  for (final utc in [true, false]) {
    final prefix = utc ? 'UTC' : '';
    for (final field in [
      'FullYear',
      'Month',
      'Date',
      'Day',
      'Hours',
      'Minutes',
      'Seconds',
      'Milliseconds',
    ]) {
      jDatePrototype.properties['get$prefix$field'] = JFunction((a, r) {
        final value = jDateReceiver(r).time;
        if (value.isNaN) return double.nan;
        final d = jDateTime(value, utc);
        return <String, int>{
          'FullYear': d.year,
          'Month': d.month - 1,
          'Date': d.day,
          'Day': d.weekday % 7,
          'Hours': d.hour,
          'Minutes': d.minute,
          'Seconds': d.second,
          'Milliseconds': d.millisecond,
        }[field]!.toDouble();
      }, constructible: false);
    }
    for (final entry in {
      'FullYear': 0,
      'Month': 1,
      'Date': 2,
      'Hours': 3,
      'Minutes': 4,
      'Seconds': 5,
      'Milliseconds': 6,
    }.entries) {
      final start = entry.value,
          count = start < 2
              ? 3 - start
              : start == 2
              ? 1
              : 7 - start;
      jDatePrototype.properties['set$prefix${entry.key}'] = JFunction((a, r) {
        final target = jDateReceiver(r), time = target.time;
        final values = [
          for (var i = 0; i < math.min(math.max(a.length, 1), count); i++)
            jNumber(jArg(a, i)),
        ];
        if (time.isNaN && start != 0) return target.time = double.nan;
        final d = time.isNaN
            ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
            : jDateTime(time, utc);
        final fields = [
          d.year.toDouble(),
          (d.month - 1).toDouble(),
          d.day.toDouble(),
          d.hour.toDouble(),
          d.minute.toDouble(),
          d.second.toDouble(),
          d.millisecond.toDouble(),
        ];
        for (var i = 0; i < values.length; i++) fields[start + i] = values[i];
        return target.time = jMakeDate(fields, utc: utc);
      }, constructible: false);
    }
  }
  jDatePrototype.properties['setTime'] = JFunction((a, r) {
    final target = jDateReceiver(r);
    return target.time = jTimeClip(jNumber(jArg(a, 0)));
  }, constructible: false);
  jDatePrototype.properties['getTimezoneOffset'] = JFunction((a, r) {
    final time = jDateReceiver(r).time;
    return time.isNaN
        ? double.nan
        : -jDateTime(time, false).timeZoneOffset.inMinutes.toDouble();
  }, constructible: false);
  jDatePrototype.properties['getYear'] = JFunction((a, r) {
    final time = jDateReceiver(r).time;
    return time.isNaN
        ? double.nan
        : (jDateTime(time, false).year - 1900).toDouble();
  }, constructible: false);
  jDatePrototype.properties['setYear'] = JFunction((a, r) {
    final target = jDateReceiver(r),
        time = target.time,
        year = jNumber(jArg(a, 0));
    if (year.isNaN) return target.time = double.nan;
    final d = time.isNaN
        ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
        : jDateTime(time, false);
    return target.time = jMakeDate(
      [
        year,
        (d.month - 1).toDouble(),
        d.day.toDouble(),
        d.hour.toDouble(),
        d.minute.toDouble(),
        d.second.toDouble(),
        d.millisecond.toDouble(),
      ],
      utc: false,
      adjustYear: true,
    );
  }, constructible: false);
  jBuiltinProperties(constructor);
  jBuiltinProperties(jDatePrototype);
  jDatePrototype.flags[jSymbols['toPrimitive']!]!.writable = false;
  constructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  jNameFunction(constructor, 'Date', 7);
  for (final entry in jDatePrototype.properties.entries) {
    if (entry.value is JFunction &&
        entry.key != 'constructor' &&
        entry.key != 'toGMTString') {
      final key = entry.key.replaceFirst('UTC', '');
      final length =
          {
            'setFullYear': 3,
            'setMonth': 2,
            'setHours': 4,
            'setMinutes': 3,
            'setSeconds': 2,
            'toJSON': 1,
          }[key] ??
          (key.startsWith('set') ? 1 : 0);
      jNameFunction(entry.value, entry.key, length);
    }
  }
  for (final entry in {'now': 0, 'parse': 1, 'UTC': 7}.entries)
    jNameFunction(constructor.properties[entry.key], entry.key, entry.value);
  scope.define('Date', constructor);
}
