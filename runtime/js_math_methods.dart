part of 'js_core.dart';

Map<String, dynamic> jMathAdditionalMethods() {
  double log1p(double x) {
    if (x == 0 || x.abs() < 1e-16) return x;
    if (x <= -1 || !x.isFinite) return math.log(1 + x);
    final y = 1 + x;
    return math.log(y) - ((y - 1) - x) / y;
  }

  double expm1(double x) {
    if (x == 0 || !x.isFinite || x.abs() > 0.5)
      return x == 0 ? x : math.exp(x) - 1;
    var term = x;
    var sum = x;
    for (var i = 2; i <= 18; i++) {
      term *= x / i;
      sum += term;
    }
    return sum;
  }

  double signed(double magnitude, double sign) =>
      sign.isNegative ? -magnitude : magnitude;
  double sinh(double x) {
    final a = x.abs();
    if (a > 20) return signed(math.exp(a - math.ln2), x);
    final e = expm1(a);
    return signed((e + e / (e + 1)) / 2, x);
  }

  double cosh(double x) {
    final a = x.abs();
    if (a > 20) return math.exp(a - math.ln2);
    final e = expm1(a);
    return 1 + e * e / (2 * (1 + e));
  }

  final unary = <String, double Function(double)>{
    'acosh': (x) => x > 1e154
        ? math.log(x) + math.ln2
        : log1p(x - 1 + math.sqrt((x - 1) * (x + 1))),
    'asinh': (x) {
      final a = x.abs();
      return signed(
        a > 1e154
            ? math.log(a) + math.ln2
            : log1p(a + a * a / (1 + math.sqrt(1 + a * a))),
        x,
      );
    },
    'atanh': (x) {
      final a = x.abs();
      return a > 1 ? double.nan : signed(log1p(2 * a / (1 - a)) / 2, x);
    },
    'cbrt': (x) {
      if (x == 0 || !x.isFinite) return x;
      final a = x.abs();
      final y = math.pow(a, 1 / 3).toDouble();
      return signed(y + (a / y / y - y) / 3, x);
    },
    'cosh': cosh,
    'expm1': expm1,
    'f16round': (x) => jFromFloat16(jFloat16(x)),
    'log1p': log1p,
    'sinh': sinh,
    'tanh': (x) {
      final a = x.abs();
      if (a > 20) return signed(1, x);
      final e = expm1(2 * a);
      return signed(e / (e + 2), x);
    },
  };
  return {
    for (final entry in unary.entries)
      entry.key: jNamedFunction(
        jBuiltin((args) => entry.value(jNumber(jArg(args, 0)))),
        entry.key,
        1,
      ),
    'sumPrecise': jNamedFunction(
      jBuiltin((args) => jMathSumPrecise(jArg(args, 0))),
      'sumPrecise',
      1,
    ),
  };
}

double jMathSumPrecise(dynamic items) {
  // Finite doubles are integer multiples of 2^-1074. Sum in that unit
  // before rounding once, instead of rounding intermediate additions.
  var sum = BigInt.zero;
  var negativeZero = true;
  var nan = false, positiveInfinity = false, negativeInfinity = false;
  jForEachIterable(items, (value) {
    if (value is! num)
      throw JThrown(JError('TypeError', 'Math.sumPrecise requires numbers'));
    final x = value.toDouble();
    if (x.isNaN) {
      nan = true;
    } else if (x.isInfinite) {
      if (x.isNegative) {
        negativeInfinity = true;
      } else {
        positiveInfinity = true;
      }
    } else if (x != 0 || !x.isNegative) {
      negativeZero = false;
      final (n, d) = jDoubleFraction(x);
      final scaled = n << (1075 - d.bitLength);
      sum += x.isNegative ? -scaled : scaled;
    }
  });
  if (nan || positiveInfinity && negativeInfinity) return double.nan;
  if (positiveInfinity) return double.infinity;
  if (negativeInfinity) return double.negativeInfinity;
  if (sum == BigInt.zero) return negativeZero ? -0.0 : 0.0;

  final magnitude = sum.abs();
  final shift = math.max(0, magnitude.bitLength - 53);
  var mantissa = magnitude >> shift;
  if (shift > 0) {
    final remainder = magnitude - (mantissa << shift);
    final halfway = BigInt.one << (shift - 1);
    if (remainder > halfway || remainder == halfway && mantissa.isOdd) {
      mantissa += BigInt.one;
    }
  }
  final value = mantissa.toDouble() * math.pow(2.0, shift - 1074);
  return sum.isNegative ? -value : value;
}
