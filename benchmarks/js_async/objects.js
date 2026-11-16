let checks = 0;
function eq(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('check ' + checks + ': ' + String(actual) + ' != ' + String(expected));
}
function error(fn, name) { let caught = ''; try { fn(); } catch (e) { caught = e.name; } eq(caught, name); }
const s = Symbol('key'), t = Symbol('key');
eq(typeof s, 'symbol'); eq(s === t, false); eq(s.description, 'key');
eq(Symbol().description, undefined); eq(String(s), 'Symbol(key)');
eq(Symbol.for('shared'), Symbol.for('shared')); eq(Symbol.keyFor(s), undefined);
eq(Symbol.keyFor(Symbol.for('shared')), 'shared');
error(() => Symbol.keyFor('shared'), 'TypeError'); error(() => new Symbol(), 'TypeError');
error(() => '' + s, 'TypeError');
const object = {z: 1, 10: 'ten', 2: 'two', [s]: 4};
eq(Object.keys(object).join(','), '2,10,z');
eq(Object.getOwnPropertySymbols(object)[0], s); eq({...object}[s], 4);
eq(Object.assign({}, object)[s], 4); eq(Object.fromEntries([[s, 9]])[s], 9);
eq(Object.is(NaN, NaN), true); eq(Object.is(-0, 0), false);
eq(Reflect.ownKeys(object)[3], s);
Object.defineProperty(object, 'locked', {value: 7});
eq(object.locked, 7); eq(Object.keys(object).includes('locked'), false);
eq(Object.getOwnPropertyDescriptor(object, 'locked').writable, false);
eq(Reflect.set(object, 'locked', 8), false);
eq(Reflect.deleteProperty(object, 'locked'), false);
error(() => { object.locked = 8; }, 'TypeError'); error(() => { delete object.locked; }, 'TypeError');
error(() => Object.defineProperty(object, 'locked', {value: 8}), 'TypeError');
eq(Object.defineProperty(object, 'locked', {value: 7}), object);
const proto = { value: null, get doubled() { return this.number * 2; }, set doubled(v) { this.number = v / 2; }};
const child = Object.create(proto);
child.number = 3; eq(child.doubled, 6); child.doubled = 10; eq(child.number, 5);
eq(child.value, null); eq(Object.getPrototypeOf(child), proto);
eq(proto.isPrototypeOf(child), true); eq(child.hasOwnProperty('doubled'), false);
eq('doubled' in child, true); eq(Reflect.get(child, 'doubled', {number: 7}), 14);
const alternate = {};
eq(Reflect.set(child, 'doubled', 12, alternate), true); eq(alternate.number, 6);
eq(Object.getPrototypeOf({__proto__: null}), null);
eq(Object.getPrototypeOf(Object.fromEntries([['__proto__', 3]])), Object.prototype);
const frozen = Object.freeze({a: 1});
eq(Object.isFrozen(frozen), true); eq(Object.isSealed(frozen), true);
eq(Object.isExtensible(frozen), false); eq(Reflect.set(frozen, 'b', 2), false);
error(() => Object.setPrototypeOf(frozen, {}), 'TypeError');
eq(Object.setPrototypeOf(frozen, Object.prototype), frozen);
eq(Reflect.setPrototypeOf(proto, child), false);
const accessOrder = [];
const descriptor = {
  get enumerable() { accessOrder.push('enumerable'); return true; },
  get configurable() { accessOrder.push('configurable'); return true; },
  get value() { accessOrder.push('value'); return 11; },
  get writable() { accessOrder.push('writable'); return true; }
};
Object.defineProperty(child, 'once', descriptor);
eq(accessOrder.join(','), 'enumerable,configurable,value,writable');
eq(child.once, 11);
const unchanged = {};
error(() => Object.defineProperties(unchanged, {a: {value: 1}, b: {get: 3}}), 'TypeError');
eq(Object.hasOwn(unchanged, 'a'), false);
const key = {[Symbol.toPrimitive](hint) { eq(hint, 'string'); return s; }};
eq(Object.fromEntries([[key, 23]])[s], 23);
console.log('objects: ' + checks + ' checks');
$DONE();
