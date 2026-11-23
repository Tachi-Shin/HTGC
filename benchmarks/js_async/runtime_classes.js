let checks = 0;
function same(actual, expected) {
  if (!Object.is(actual, expected)) throw new Error(actual + " != " + expected);
  checks++;
}

class Base {
  value() { return 3; }
  static label() { return "base"; }
}
const steps = [];
function observe(value) { steps.push(value); return value; }
const source = String.raw`
  return class Derived extends Base {
    valueField = super.value();
    callback = () => this.valueField;
    declarationOnly;
    [observe("method")]() { return this.callback() + 1; }
    get reading() { return this.valueField; }
    set reading(value) { this.valueField = value; }
    static computed = observe(super.label());
    static { observe(Derived === this ? "static block" : "wrong receiver"); }
    static [observe("info")]() { return Derived.name; }
  };
`;
const Derived = Function("Base", "observe", source)(Base, observe);
same(steps.join("|"), "method|info|base|static block");
same(Derived.name, "Derived");
same(Derived.info(), "Derived");
same(Derived.computed, "base");
const instance = new Derived();
same(instance instanceof Base, true);
same(instance instanceof Derived, true);
same(instance.method(), 4);
same(instance.declarationOnly, undefined);
same(Object.hasOwn(instance, "declarationOnly"), true);
instance.reading = 8;
same(instance.reading, 8);
same(instance.method(), 9);

function runEval() {
  const code = "class Local extends Base { name() { return Local.name; } }; new Local().name()";
  return eval(code + "");
}
same(runEval(), "Local");
const makeEmpty = Function("name", "return class RuntimeArray extends " + Uint8Array.name + " {}");
const view = new (makeEmpty())([7, 9]);
same(view instanceof Uint8Array, true);
same(view[1], 9);

for (const [body, expected] of [
  ["return class Self extends Self {}", "ReferenceError"],
  ["return class { static ['prototype']() {} }", "TypeError"],
]) {
  let name;
  try { Function(body + "")(); } catch (error) { name = error.name; }
  same(name, expected);
}
const code = `
  return class Derived extends Base {
    #value;
    static #count = 0;
    #method() { return this.#value; }
    constructor(value, ...rest) {
      const initialize = () => super(...rest);
      initialize();
      this.#value = value + super.value();
      this.target = new.target;
      Derived.#count++;
    }
    get #data() { return this.#method(); }
    set #data(value) { this.#value = value; }
    readValue() { return this.#data; }
    setValue(value) { this.#data = value; }
    static count() { return this.#count; }
    has(candidate) { return #value in candidate; }
    nested() { return class Nested { read(target) { return target.#value; } }; }
  };
`;
const buildPrivate = Function("Base", code);
const First = buildPrivate(Base), Second = buildPrivate(Base);
const first = new First(5), second = new Second(1);
same(First.length, 1);
same(first.target, First);
same(first.readValue(), 8);
first.setValue(10);
same(first.readValue(), 10);
same(first.has(first), true);
same(first.has(second), false);
same(First.count(), 1);
same(new (first.nested())().read(first), 10);

const runtimeEvalConstructor = [
  "return class extends Parent {",
  "  #value = 9;",
  "  constructor(text) { eval(text); }",
  "  read(text) { return eval(text); }",
  "};",
].join("\n");
const EvalClass = Function("Parent", runtimeEvalConstructor)(Base);
const evaluated = new EvalClass("super()");
same(evaluated.read("this.#value"), 9);

class CompiledDerived extends Base {
  #value = 42;
  constructor(text) {
    if (text) eval(text);
    else eval("super()");
  }
  read(text) {
    return text ? eval(text) : eval("this.#value");
  }
}
same(new CompiledDerived("super()").read("this.#value"), 42);
same(new CompiledDerived().read(), 42);
const ArrayClass = Function("source", "return eval(source)")(
  "class Numbers extends Array { #brand = 1; tag = 5; check() { return #brand in this; } }; Numbers"
);
const array = new ArrayClass(2);
same(Array.isArray(array), true);
same(array.length, 2);
same(array.tag, 5);
same(array.check(), true);
let effects = 0;
class Standalone {
  constructor() {
    try { eval("effects++; super()"); } catch (error) { same(error.name, "SyntaxError"); }
  }
}
new Standalone();
same(effects, 0);
for (const invalid of [
  "return class { constructor() {} constructor() {} }",
  "return class { #duplicate; static #duplicate; }",
  "return class { read() { return this.#missing; } }",
  "return class { #value; clear() { delete this.#value; } }",
]) {
  let name;
  try { Function(invalid + ""); } catch (error) { name = error.name; }
  same(name, "SyntaxError");
}

const japanese = Function(String.raw`return class メモ {
  #値 = 40;
  #\u{10400} = 2;
  読む() { return this.#\u5024 + this.#𐐀; }
}` + "");
const 記録 = japanese();
same(記録.name, "メモ");
same(new 記録().読む(), 42);
const FieldEval = Function("return class { field = eval('arguments' + ''); }" + "");
let fieldError;
try { new (FieldEval())(); } catch (error) { fieldError = error.name; }
same(fieldError, "SyntaxError");

console.log("runtime classes: " + checks + " checks");
$DONE();
