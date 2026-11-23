const check = (actual, expected) => {
  if (!Object.is(actual, expected)) throw new Error(String(actual) + ' != ' + expected);
};
const source = [
  "let outer = 20;",
  "with (obj) {",
  "  const before = outer;",
  "  const closure = () => method();",
  "  outer += 3;",
  "  return [before, outer, closure, method?.(), eval('method()')];",
  "}",
].join("\n");
const run = Function("obj", source);
const object = {outer: 4, method() { return this; }};
const result = run(object);
check(result[0], 4);
check(result[1], 7);
check(object.outer, 7);
check(result[2](), object);
check(result[3], object);
check(result[4], object);
object[Symbol.unscopables] = {outer: true};
const excluded = run(object);
check(excluded[0], 20);
check(excluded[1], 23);
check(object.outer, 7);
const trace = [];
const target = {v: 1};
const proxy = new Proxy(target, {
  has(t,k) { trace.push("has:" + String(k)); return Reflect.has(t,k); },
  get(t,k,r) { trace.push("get:" + String(k)); return Reflect.get(t,k,r); },
  set(t,k,v) { trace.push("set:" + String(k)); return Reflect.set(t,k,v); }
});
Function("obj", "with (obj) v += 2;")(proxy);
check(target.v, 3);
check(trace[0], "has:v");
check(trace[trace.length - 1], "set:v");
const invoke = Function("env", "with(env) return eval('5') + Function('8');");
const custom = {n: 5, eval(str) { return this.n + str; }, Function(str) { return this.n + str; }};
check(invoke(custom), '5558');
const checkArray = Function("arr", "let values = 99; with (arr) return values;");
check(checkArray([]), 99);
const get = Function("env", "with(env){ return () => v; }");
const a = get({v: "first"}), b = get({v: "second"});
check(a(), "first");
check(b(), "second");
let failure;
try { Function("value", "'use strict'; with(value){}"); } catch (e) { failure = e.name; }
check(failure, 'SyntaxError');
console.log("with: pass");
$DONE();
