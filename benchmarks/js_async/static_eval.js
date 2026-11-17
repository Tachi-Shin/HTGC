function example() {
  let local = 2;
  console.log(eval('local + 3'));
  console.log(eval('local = local + 5'));
  console.log(local);
  console.log(eval('let temp = 8; temp * 2'));
  console.log(eval('1; let x = 0;'), eval('1; if (false) 2;'));
  console.log(eval('1; { let x = 1; }'), eval('1; while (false) 3;'));
  console.log(eval('1; try { 2; } finally { 3; }'));
  console.log(eval('function f() { 99; return 5; } f();'));
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
  yield (function* () {}).constructor('yield 8;')().next().value;
}
console.log([...generator()].join(','));
const object = { value: 6, method() { return eval('this.value'); } };
console.log(object.method());
console.log((function () {}).constructor('x', 'return x + 1')(4));
console.log([...(function* () {}).constructor('yield 2; yield 4;')()].join(','));
const GeneratorFunction = Object.getPrototypeOf(function* () {}).constructor;
console.log(GeneratorFunction('yield 11;')().next().value);
let Dynamic = (async function () {}).constructor;
Dynamic = function (value) { return 'replacement:' + value; };
console.log(Dynamic('value'));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const AsyncGeneratorFunction = Object.getPrototypeOf(async function* () {}).constructor;
async function asyncExample() {
  console.log(await AsyncFunction('return 13;')());
  console.log((await new AsyncGeneratorFunction('yield 17;')().next()).value);
  console.log(await (async function () {}).constructor('x', 'return x + 3')(5));
  const asyncGen = (async function* () {}).constructor('yield 3; yield 6;')();
  console.log((await asyncGen.next()).value, (await asyncGen.next()).value);
  let value = 2;
  return await eval('Promise.resolve(value + 5)');
}
asyncExample().then(value => { console.log(value); $DONE(); }, $DONE);
