let checks = 0;
function same(actual, expected) {
  if (!Object.is(actual, expected)) {
    throw new Error("check " + (checks + 1) + ": " + actual + " != " + expected);
  }
  checks++;
}
function throws(expected, call) {
  try { call(); } catch (error) { same(error.name, expected); return; }
  throw new Error("expected " + expected);
}
class Derived extends Array {
  #label = "derived";
  message() { return this.#label + ":" + this.length; }
}
const d = new Derived(3);
d[0] = 4;
d[2] = 8;
same(d.message(), "derived:3");
same(d instanceof Array, true);
same(d instanceof Derived, true);
same(Array.isArray(Array.prototype), true);
same(Array.prototype.length, 0);
same(d.map, Array.prototype.map);
same(Array.prototype.values, Array.prototype[Symbol.iterator]);
for (const output of [d.map(n => n * 2), d.filter(n => n > 0), d.slice(), d.flat(),
                      d.flatMap(n => [n]), d.concat([9]), d.splice(0, 0)]) {
  same(output instanceof Derived, true);
}
same(1 in d.map(n => n * 2), false);
same(d.slice(0, 3).join(":"), "4::8");
same(Derived.from([1, 2]) instanceof Derived, true);
same(Derived.of(1, 2) instanceof Derived, true);
same(d.toReversed() instanceof Derived, false);

const allocations = [];
function Result(length) { allocations.push(length); }
class WithSpecies extends Array {
  static get [Symbol.species]() { return Result; }
}
const result = new WithSpecies(7, 8, 9).slice(1);
same(result instanceof Result, true);
same(result.length, 2);
same(result[0], 8);
same(allocations.join(), "2");

const hole = [1,,3];
const prototype = [9,8];
same(Object.setPrototypeOf(hole, prototype), hole);
same(Object.getPrototypeOf(hole), prototype);
same(hole.join(), "1,8,3");
same(hole.map(x => x + 1).join(), "2,9,4");
same(Object.hasOwn(hole, "1"), false);

const shrink = [0,1,2,3];
Object.defineProperty(shrink, "1", {configurable:false});
same(Reflect.defineProperty(shrink, "length", {value:0, writable:false}), false);
same(shrink.length, 2);
same(2 in shrink, false);
same(Reflect.set(shrink, "2", 2), false);
same(Object.getOwnPropertyDescriptor(shrink, "length").writable, false);
throws("RangeError", () => Reflect.set([], "length", 1.5));
const coercions = [];
const box = { valueOf() { coercions.push("length"); return 3; } };
same(Reflect.set(shrink, "length", box), false);
same(coercions.length, 0);
const writable = [];
Object.defineProperty(writable, "length", {value: box});
same(coercions.length, 2);
same(writable.length, 3);

const sparseLiteral = [3];
sparseLiteral[4294967294] = 5;
same(sparseLiteral.length, 4294967295);
same(sparseLiteral[0], 3);
same(Reflect.ownKeys(sparseLiteral).join(), "0,4294967294,length");
sparseLiteral.length = 1;
same(Reflect.ownKeys(sparseLiteral).join(), "0,length");
const huge = Array(4294967295);
huge[4294967294] = 3;
same(huge.length, 4294967295);
same(Reflect.ownKeys(huge).join(), "4294967294,length");
same(Reflect.deleteProperty(huge, "04294967294"), true);
same(huge[4294967294], 3);
huge.length = 0;
same(Reflect.ownKeys(huge).join(), "length");

const frozen = Object.freeze([5,6]);
same(Object.isFrozen(frozen), true);
const view = new Proxy(frozen, {});
same(Reflect.set(view, "0", 0), false);
same(Reflect.deleteProperty(view, "1"), false);
same(Reflect.isExtensible(view), false);
same(Reflect.defineProperty(view, "2", {value: 3}), false);
same(Reflect.ownKeys(view).join(), "0,1,length");
throws("TypeError", () => Object.keys(new Proxy(frozen, {ownKeys: () => ["length"]})));

const getter = [];
Object.defineProperty(getter, "0", {get() { return this.tag; }});
getter.tag = "get";
same(getter[0], "get");
same(Reflect.get(getter, "0", {tag:"receiver"}), "receiver");
same(Reflect.get(new Proxy(getter, {}), "0", {tag:"proxy receiver"}), "proxy receiver");

const order = [];
const keyObject = { toString() { order.push("key"); return "0"; } };
const keyed = [];
keyed[keyObject] = (order.push("rhs"), 2);
same(order.join(), "rhs,key");
same(keyed[0], 2);
const ignoreFrozenAssignment = Function("array", "array[0] = 1; return array[0]");
same(ignoreFrozenAssignment(frozen), 5);
same(JSON.stringify({a: 1,b: 2}, new Proxy(["b"], {})), '{"b":2}');
const customJSON = [5,6];
customJSON.toJSON = () => 13;
same(JSON.stringify(customJSON), "13");

(async () => {
  const converted = await Derived.fromAsync([3,4], n => n ** 2);
  same(converted instanceof Derived, true);
  same(converted.join(), "9,16");
  console.log("arrays: " + checks + " checks");
})().then(() => $DONE(), error => $DONE(error));
