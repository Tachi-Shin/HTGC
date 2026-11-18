globalThis.indirectValue = 7;
function example() {
  let indirectValue = 42;
  console.log((0, eval)('indirectValue + 1'));
  console.log(globalThis.eval('indirectValue'));
  console.log(globalThis['eval']('this === globalThis'));
  console.log(eval?.('indirectValue'));
  const indirect = eval;
  console.log(indirect('indirectValue'));
  let shadow = { eval(x) { return 'custom:' + x; } };
  const alias = shadow.eval;
  console.log(alias('hello'));
  const obj = {value: 9, eval(x) { return this.value + ':' + x; }};
  console.log(obj.eval('hello'));
  console.log(obj.eval('with (obj) {}'));
  console.log((0, eval)('1 + 1', (() => 5)()));
  console.log((0, obj.eval)('ignored'));
}
try { example(); } catch (error) { console.log(error.name); }
try { (0, eval)('let = ;'); } catch (error) { console.log(error.name); }
$DONE();
