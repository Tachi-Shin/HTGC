let checks = 0;
function same(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('class check ' + checks + ': ' + String(actual) + ' != ' + String(expected));
}
function assertThrows(name, body) {
  let actual = '';
  try { body(); } catch (error) { actual = error.name; }
  same(actual, name);
}

let event = '';
class Base {
  field = (event += 'base-field;');
  constructor(value) {
    event += 'base-body;';
    this.value = value;
    this.constructedAs = new.target;
  }
  get doubled() { return this.value * 2; }
  set update(value) { this.value = value; }
  render() { return 'base-' + this.value; }
  static kind() { return this.name; }
}
class Derived extends Base {
  #increment = 2;
  #step() { return this.#increment; }
  get #doubled() { return this.#step() * 2; }
  set #doubled(value) { this.#increment = value / 2; }
  field = (event += 'derived-field;');
  static #counter = 5;
  static result = super.kind();
  static { this.#counter++; this.counter = this.#counter; }
  constructor(value) {
    event += 'derived-before;';
    super(value);
    event += 'derived-after;';
  }
  get step() { return this.#step(); }
  measure() { return super.doubled + this.#doubled; }
  change(value) { super.update = value; this.#doubled = value; }
  render() { return super.render() + '-derived'; }
  static canAccess(receiver) { return #increment in receiver; }
  static readCounter() { return this.#counter; }
  *values() { yield this.#increment; yield super.doubled; }
}

const item = new Derived(3);
same(event, 'derived-before;base-field;base-body;derived-field;derived-after;');
same(item instanceof Derived, true);
same(item instanceof Base, true);
same(item.constructedAs, Derived);
same(item.measure(), 10);
same(item.render(), 'base-3-derived');
same(item.step, 2);
item.change(8);
same(item.step, 4);
same(item.measure(), 24);
same([...item.values()].join(','), '4,16');
same(Derived.result, 'Derived');
same(Derived.counter, 6);
same(Derived.readCounter(), 6);
same(Derived.canAccess(item), true);
same(Derived.canAccess({}), false);
same(Derived.canAccess(new Proxy(item, {})), false);
assertThrows('TypeError', () => Derived.canAccess(1));
assertThrows('TypeError', () => Derived.prototype.measure.call({value: 1}));
assertThrows('TypeError', () => Derived(1));
class Child extends Derived {}
assertThrows('TypeError', () => Child.readCounter());
same(new Child(3).constructedAs, Child);
same(Object.keys(item).includes('#increment'), false);
same(Derived.length, 1);

class EarlyError extends Base { constructor() { this.value = 2; super(1); } }
assertThrows('ReferenceError', () => new EarlyError());
class NoBinding extends Base { constructor() {} }
assertThrows('ReferenceError', () => new NoBinding());
class ReturnsObject extends Base { constructor() { return {ok: true}; } }
same(new ReturnsObject().ok, true);
class Primitive extends Base { constructor() { super(1); return 2; } }
assertThrows('TypeError', () => new Primitive());
class ConstructDate extends Date { constructor(year) { super(Date.UTC(year, 0, 1)); } }
same(new ConstructDate(2024).getUTCFullYear(), 2024);

let order = '';
class Ordered {
  static [(order += 'a')] = (order += 'c');
  [(order += 'b')] = 1;
  static { order += 'd'; }
}
same(order, 'abcd');
same(new Ordered().ab, 1);
function brand() {
  return class {
    #value = 1;
    owns(x) { return #value in x; }
  };
}
const One = brand(), Two = brand();
same(new One().owns(new Two()), false);
same(new One().owns(new One()), true);

console.log('class members: ' + checks + ' checks');
$DONE();
