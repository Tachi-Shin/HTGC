globalThis.globalNumber = 9;
function test() {
  let value = 2;
  let source = 'value = value + 3; value * 2';
  console.log(eval(source), value);
  source = 'typeof missing';
  console.log(eval(source));
  source = '(value > 2) && (value + 1)';
  console.log(eval(source));
  const indirect = eval;
  source = 'globalNumber + 1';
  console.log(indirect(source));
  source = 'value = 100; let = ;';
  try { eval(source); } catch (error) { console.log(error.name, value); }
  const obj = { value: 4, add(n) { return this.value + n; } };
  source = 'obj.add(value)';
  console.log(eval(source));
  source = "obj['value'] = value + 1; obj.value";
  console.log(eval(source), obj.value);
  source = 'typeof obj.add';
  console.log(eval(source));
  let order = '';
  function base() { order += 'b'; return obj; }
  function key() { order += 'k'; return 'value'; }
  function rhs() { order += 'r'; return 12; }
  source = 'base()[key()] = rhs()';
  console.log(eval(source), order);
  source = 'base().add(rhs())';
  order = '';
  console.log(eval(source), order);
  for (const expression of [
    'value += 2', 'value *= 3', 'value -= 1', 'value /= 2',
    'value %= 4', 'value **= 2', 'value <<= 1', 'value >>= 1',
    'value >>>= 0', 'value |= 8', 'value &= 15', 'value ^= 2',
    'value &&= 0', 'value ||= 4', 'value ??= 99',
    'value > 0 ? value : missing', 'false ? missing : true ? 7 : 8',
    '1 | 2 & 4 ^ 8',
  ]) console.log(eval(expression));
  source = 'base()[key()] += rhs()';
  order = '';
  console.log(eval(source), order);
  source = 'obj.value ||= rhs()';
  order = '';
  console.log(eval(source), order);
  for (const expression of [
    'let temp = value + 1; temp * 2',
    'const temp = 3, other = temp + 1; other',
    '1; let temp;',
    'let temp = 3; { let temp = 5; temp }; temp',
    'let temp = 3; { typeof temp; let temp = 5 }',
    '1; { let temp = 2 }',
    '1; if (false) { 2 }',
    'if (true) { null } else { missing }',
    'if (false) missing; else 9',
    'value = 99; if (false) { let temp; let temp; }',
    'let temp = temp',
    'const temp = 1; temp = 2',
    'value = 99; let temp; let temp;',
  ]) {
    try { console.log(eval(expression)); }
    catch (error) { console.log(error.name); }
  }
  console.log(value, typeof temp);
  const nonString = {};
  console.log(eval(nonString) === nonString);
}
test();
let params = 'a,b';
let body = 'return a + b;';
console.log(Function(params, body)(3, 4));
body = 'return globalNumber';
console.log(new Function(body)());
body = 'return this.value';
console.log(Function(body).call({value: 15}));
body = 'return arguments[1]';
console.log(Function(body)(1, 8));
body = 'let x = 3; const y = x + 2; x += y; return x; missing()';
console.log(Function(body)());
body = 'let x = 1\nx += 2\nreturn x';
console.log(Function(body)());
body = 'return\n42';
console.log(Function(body)());
body = '"use strict"\nreturn this';
console.log(Function(body)() === undefined);
body = 'if (arguments[0]) { let result = 3; return result } else { throw 5 }';
const branch = Function(body);
console.log(branch(true));
try { branch(false); } catch (value) { console.log(value); }
body = 'throw 17';
try { Function(body)(); } catch (value) { console.log(value); }
params = 'a';
body = 'return 1; let a;';
try { Function(params, body); } catch (error) { console.log(error.name); }
$DONE();
