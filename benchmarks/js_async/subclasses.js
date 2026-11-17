let checks = 0;
function eq(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('subclass check ' + checks + ': ' + actual + ' != ' + expected);
}
function throwsTypeError(f) {
  let name = '';
  try { f(); } catch (error) { name = error.name; }
  eq(name, 'TypeError');
}

class Day extends Date {
  year() { return this.getUTCFullYear(); }
  static label() { return 'day'; }
  get iso() { return this.toISOString(); }
}
class ChildDay extends Day {}
const day = new ChildDay('2024-02-29');
eq(day instanceof Date, true);
eq(day instanceof Day, true);
eq(day instanceof ChildDay, true);
eq(day.year(), 2024);
eq(day.iso, '2024-02-29T00:00:00.000Z');
eq(ChildDay.label(), 'day');
eq(Object.getPrototypeOf(Day), Date);
eq(Object.getPrototypeOf(Day.prototype), Date.prototype);
eq(Object.getOwnPropertyDescriptor(Day.prototype, 'year').enumerable, false);
throwsTypeError(() => Day());
throwsTypeError(() => new day.year());

class Ints extends Uint16Array { sum() { return this.reduce((a, b) => a + b, 0); } }
const ints = new Ints([3, 5, 8]);
eq(ints instanceof Uint16Array, true);
eq(ints instanceof Ints, true);
eq(ints.sum(), 16);
class Pattern extends RegExp {}
const pattern = new Pattern('x', 'g');
eq(pattern instanceof Pattern, true);
eq(pattern.exec('xx')[0], 'x');
eq(pattern.lastIndex, 1);
class Buffer extends ArrayBuffer {}
class View extends DataView {}
const buffer = new Buffer(2);
const view = new View(buffer);
view.setUint16(0, 440);
eq(view.getUint16(0), 440);
eq(buffer instanceof Buffer, true);
eq(view instanceof View, true);

const Make = class Local { ['value']() { return Local; } };
eq(new Make().value(), Make);
eq(Make.name, 'Local');
eq(Reflect.construct(Date, [0], Day).year(), 1970);

eq(ints.map(x => x + 1) instanceof Ints, true);
eq(ints.filter(x => x > 3) instanceof Ints, true);
eq(ints.slice(1) instanceof Ints, true);
eq(ints.subarray(1) instanceof Ints, true);
eq(ints.toReversed() instanceof Ints, false);
eq(buffer.slice(0, 1) instanceof Buffer, true);
class Shared extends SharedArrayBuffer {}
eq(new Shared(4).slice() instanceof Shared, true);
class Converted extends Int8Array {
  static get [Symbol.species]() { return Float64Array; }
}
const converted = new Converted([1, 3, 5]);
eq(converted.map(x => x / 2) instanceof Float64Array, true);
eq(converted.map(x => x / 2).join(','), '0.5,1.5,2.5');
eq(converted.slice(1).join(','), '3,5');
let log = [];
class Observed extends Uint16Array {
  static get [Symbol.species]() {
    log.push('species');
    return Uint16Array;
  }
}
new Observed([1]).map(x => { log.push('map'); return x; });
new Observed([1]).filter(x => { log.push('filter'); return true; });
eq(log.join(','), 'species,map,filter,species');
class WrongContent extends Int8Array {
  static get [Symbol.species]() { return BigInt64Array; }
}
throwsTypeError(() => new WrongContent([1]).slice());
const typed = Object.getPrototypeOf(Uint8Array);
eq(Object.getPrototypeOf(Int8Array), typed);
eq(Object.getOwnPropertyDescriptor(typed, Symbol.species).get.call(Ints), Ints);
throwsTypeError(() => new typed());
eq(Ints.of(2, 3) instanceof Ints, true);
eq(Ints.from([2, 3], x => x * 2).join(','), '4,6');
eq(Ints.from([2, 3]) instanceof Ints, true);
eq(typed.from.call(Float32Array, {0: 1.5, length: 1})[0], 1.5);

console.log('subclasses: ' + checks + ' checks');
$DONE();
