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
  const nonString = {};
  console.log(eval(nonString) === nonString);
}
test();
$DONE();
