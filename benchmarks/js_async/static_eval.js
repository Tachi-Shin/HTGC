function example() {
  let local = 2;
  console.log(eval('local + 3'));
  console.log(eval('local = local + 5'));
  console.log(local);
  console.log(eval('let temp = 8; temp * 2'));
  console.log(typeof temp);
  try { eval('let = ;'); } catch (error) { console.log(error.name); }
  console.log(eval(17), eval());
}
example();
console.log(Function('a', 'b', 'return a + b;')(2, 3));
console.log(new Function('x', 'return x * 3;')(4));
console.log(Function('return 9;')());
try { Function('a', 'return ; %'); } catch (error) { console.log(error.name); }
function shadow(Function) {
  console.log(Function('text'));
}
shadow(x => 'function:' + x);
function* generator() {
  let value = 4;
  yield eval('value + 1');
  yield Function('a', 'return a + 2')(value);
}
console.log([...generator()].join(','));
const object = { value: 6, method() { return eval('this.value'); } };
console.log(object.method());
async function asyncExample() {
  let value = 2;
  return await eval('Promise.resolve(value + 5)');
}
asyncExample().then(value => { console.log(value); $DONE(); }, $DONE);
