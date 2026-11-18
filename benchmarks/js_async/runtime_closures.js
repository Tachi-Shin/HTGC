function evaluate(source) { return eval(source); }

for (const source of [
  'run(6); function run(n) { return n < 2 ? 1 : n * run(n - 1) }',
  'function f() { return 1 } function f() { return 2 } f()',
  'function f() { return 1 } { result = f(); function f() { return 2 } } [result, f()].join(":")',
  'let start = 2; let f = function next(v) { return v ? next(v - 1) + 1 : start }; start = 4; [f(3), typeof next].join(":")',
  'let f = (first = 1, ...more) => first + more[1]; f(undefined, 2, 3)',
  '[1, 2, 3].map(x => y => x * y).map(f => f(2)).join(",")',
  'let fs = []; for (let i = 0; i < 3; i++) fs.push(() => i); fs.map(f => f()).join("")',
  'let fs = []; for (const x of [1, 2]) { let y = 10; fs.push(() => ++y + x) }; fs.map(f => f()).join(":")',
  'function make(x) { return () => ++x }; const a = make(0), b = make(10); [a(), b(), a()].join(":")',
  'function F(x) { this.x = x; this.target = () => new.target }; const o = new F(7); o.x + ":" + (o.target() === F)',
  'function f() { return (() => this.n + arguments[0])() }; f.call({n: 5}, 3)',
  'const f = ( {v} ) => { /* keep trivia */ return v }; f.toString()',
  'function f() {} f instanceof Function',
  'const f = (x = 1) => x; new f()',
  'function f(a, a) {}',
  'function f(a = 1) { "use strict"; return a }',
  'let changed = 0; changed = 1; function f() { return let }',
  'const obj = {n:7, f: function() {return this.n}}; (obj?.f)()',
  'let i = 0; let obj = null; obj?.[i++].f(i++); i',
  'let i = 0; let obj = {}; obj.f?.(i++); i',
  'let i = 0; let obj = null; try { (obj?.f)(i++) } catch (error) { i + ":" + error.name }',
  'let a = {}; a?.x = 1',
  'let obj = {C: function F(x) {this.x=x}}; new obj.C(8).x',
  'let make = function() {return function(x) {this.v=x}}; new (make())(3).v',
  'new new Function("return function(){this.v=5}")().v',
  'new Object?.()',
  '"p" in {p: false}',
  'for (let k in {a: 0}) { k }',
  'debugger; 12',
  'let s = ""; outer: for (let i of [1,2]) { inner: for (let j of [3,4]) { s += i+j; continue outer } }; s',
  'let s = ""; label: { s = 5; break label; s = 9 }; s',
  'label: { continue label }',
  'first: first: {}',
  'let s = ""; switch(4) { case 1: s+="a"; default: s+="d"; case 4: s+="b"; case 8: s+="c"; }; s',
  'switch (2) { case 1: let x=5; break; default: typeof x }',
  'switch (2) { case 2: f(); break; case 3: function f() {return 11} }',
  'let i=0; outer: while (++i < 4) { switch(i) { case 1: continue outer; case 2: break; default: break outer } }; i',
  'label: { switch(1) { case 1: 7; break label } }',

  'let n = 0; const o = {get x() {return n}, set x(v) {n=v}, [ "run" ](x) {return this.x+x}}; o.x=4; o.run(3)',
  'const key = Symbol("x"); const o = {[key]() {}, get x() {}}; [o[key].name, Object.getOwnPropertyDescriptor(o, "x").get.name].join(":")',
  'const o = {__proto__: {f() {return this.n}}, n: 4, f() {return () => super.f()}}; o.f()()',
  'const o = {get x(a) {return a}}',
  'const o = {set x(...xs) {}}',
  'const o = {f() {}}; new o.f()',
  'const fn = () => 0; let f; f = function() {}; [fn.name, f.name, ({x: () => 2}).x.name].join(":")',
  'let hits = 0; let o = { get x() { hits++; return 1 } }; delete o?.x; delete o?.y; delete (null)?.[hits++]; hits',

]) {
  let result;
  try { result = eval(source); }
  catch (error) { result = error.name; }
  console.log(result);
}

function Entry(arg) {
  const dynamicSource = 'new.target';
  return {staticTarget: eval('new.target'), dynamicTarget: eval(dynamicSource)};
}
const enter = new Entry(2);
console.log(enter.staticTarget === Entry, enter.dynamicTarget === Entry);
console.log(Entry().staticTarget === undefined, Entry().dynamicTarget === undefined);
for (const source of ['eval("new.target")', '(0, eval)("new.target")', 'new.target']) {
  try { console.log(evaluate(source)); }
  catch (error) { console.log(error.name); }
}

const proto = {method() { return this.n; }};
const child = {__proto__: proto, n: 6, method() {
  const dynamic = 'super.method()';
  return [super.method(), eval('super.method()'), eval(dynamic)].join(':');
}};
console.log(child.method(), child.method.name);
const body = 'function outer(x) { return function inner(y=x) { return y + 1 } }; return outer(8)()';
console.log(Function(body)());
const sloppy = Function('code', 'eval(code); return typeof added + ":" + (typeof f === "function" ? f() : 0)');
console.log(sloppy('var added = 4; function f(){ return ++added }'));
const scopes = Function('code', 'let x = 3; try { eval(code) } catch(e) { return e.name + ":" + typeof earlier }; return x');
console.log(scopes('var earlier = 0, x = 8'));
for (const source of [
  'eval("var local=7"); return local',
  'eval("var local"); return delete local + ":" + typeof local',
  'var local=3; eval("var local=8"); return (delete local) + ":" + local',
  'eval("function f(){ return x }"); let x=9; return f()',
  'let x=2; { let y=3; try { eval("var x; var y") } catch(e) {return e.name} }',
  'try {throw 1} catch (x) {eval("var x=2"); if (x!==2) return 0}; return typeof x',
]) console.log(Function(source)());
const ieval = eval;
let program = 'var evalExposed=2; function evalFn(){ return evalExposed }';
ieval(program);
console.log(globalThis.evalFn(), Object.getOwnPropertyDescriptor(globalThis, 'evalExposed').configurable);
delete globalThis.evalExposed;
delete globalThis.evalFn;
function checkArguments(make) {
  const fn = make('a', 'a = 3; const before = arguments[0]; arguments[0] = 7; const after = a; Object.defineProperty(arguments, "0", {writable: false}); a=8; return [before, after, arguments[0], arguments.callee === arguments.callee].join(":")');
  console.log(fn(1));
  console.log(make('x,x', 'x=4; return [arguments[0], arguments[1], x].join(":")')(1,2));
  console.log(make('x,x', 'x=4; return [arguments[0], arguments[1], x].join(":")')(1));
  console.log(make('a', 'Object.defineProperty(arguments, "0", {get(){return 9}}); a=3; return a + ":" + arguments[0]')(5));
  console.log(make('a', 'delete arguments[0]; arguments[0]=8; return a + ":" + arguments[0]')(5));
  console.log(make('arguments', 'return arguments')(8));
}
checkArguments(Function);
const staticMapped = Function('a', 'arguments[0]++; return a');
console.log(staticMapped(8));
console.log(Function('a,a', 'return a')(1,3), Function('return typeof anonymous')());
console.log(Function('arg=() => outer', 'var outer=3; try {return arg()} catch(e) {return e.name}')());
$DONE();
