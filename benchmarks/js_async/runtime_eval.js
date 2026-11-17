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
$DONE();
