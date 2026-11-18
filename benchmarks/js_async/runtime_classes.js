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
console.log("runtime classes: " + checks + " checks");
$DONE();
