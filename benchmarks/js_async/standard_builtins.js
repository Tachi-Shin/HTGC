let checks = 0;
function same(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('built-in check ' + checks + ': ' + String(actual) + ' != ' + String(expected));
}
function throwsName(name, body) {
  let actual = '';
  try { body(); } catch (error) { actual = error.name; }
  same(actual, name);
}
function has(array, index) { return Object.prototype.hasOwnProperty.call(array, index); }

const source = [1, , 4];
const reversed = source.toReversed();
same(reversed.join('/'), '4//1');
same(has(reversed, 1), true);
same(has(source, 1), false);
same(source.findIndex(x => x === undefined), 1);
same(source.findLastIndex(x => x > 0), 2);
same(source.findLast(x => x > 0), 4);
same(source.reduce((a, b) => a + b), 5);
same(source.reduceRight((a, b) => String(a) + b), '41');
same(source.at(-1), 4);
same(source.lastIndexOf(undefined), -1);
same(source.concat([8, , 9]).join('/'), '1//4/8//9');
same([1, [2, [, 3]]].flat(2).join('/'), '1/2/3');
same(source.flatMap(x => [x, x + 1]).join('/'), '1/2/4/5');
same([3, , 1].toSorted((a, b) => a - b).join('/'), '1/3/');
same(source.toSpliced(1, 1, 9).join('/'), '1/9/4');
same(source.with(-1, 2).join('/'), '1//2');
throwsName('RangeError', () => source.with(-4, 0));
throwsName('TypeError', () => [].reduce(() => 1));
const sparse = [1, , 3, 4];
sparse.copyWithin(1, 0, 3);
same(sparse.join('/'), '1/1//3');
same(has(sparse, 2), false);
sparse.reverse();
same(sparse.join('/'), '3//1/1');
same(sparse.shift(), 3);
same(has(sparse, 0), false);
same(sparse.unshift(5, 6), 5);
const deleted = sparse.splice(1, 3, 7);
same(has(deleted, 1), false);
same(deleted.join('/'), '6//1');
same(sparse.fill(9, -1).join('/'), '5/7/9');
same(Array.prototype.at.call({ 1: 'generic', length: 2 }, -1), 'generic');
same([1, 2].toLocaleString(), '1,2');

same('a😀'.at(-1).charCodeAt(0), 0xde00);
same('😀'.codePointAt(0), 0x1f600);
same('😀'.codePointAt(1), 0xde00);
same('x'.charAt(99), '');
same('x'.charCodeAt(99), NaN);
same('x'.concat('-','y'), 'x-y');
same('abcabc'.indexOf('b', 2), 4);
same('abcabc'.lastIndexOf('b', NaN), 4);
same('abcabc'.lastIndexOf('b', -1), -1);
same('abc'.includes('a', 1), false);
same('abc'.startsWith('b', 1), true);
same('abc'.endsWith('b', 2), true);
throwsName('TypeError', () => 'abc'.includes(/a/));
same('x'.padStart(4, 'ab'), 'abax');
same('x'.padEnd(4, 'ab'), 'xaba');
same('abc'.substring(2, 0), 'ab');
same('abc'.slice(-2, -1), 'b');
same('abc'.substr(-2, 1), 'b');
same('ab'.repeat(3), 'ababab');
throwsName('RangeError', () => 'x'.repeat(-1));
same('  x\n'.trimStart(), 'x\n');
same('  x\n'.trimEnd(), '  x');
same('\ud800'.isWellFormed(), false);
same('\ud800x\udc00'.toWellFormed(), '\ufffdx\ufffd');
same('😀'.isWellFormed(), true);
same('x'.link('"'), '<a href="&quot;">x</a>');
same(String.raw({ raw: ['a', '\\n', 'z'] }, 9), 'a9\\nz');
same(encodeURI('a😀/#? []'), 'a%F0%9F%98%80/#?%20%5B%5D');
same(encodeURIComponent(':/? 日本'), '%3A%2F%3F%20%E6%97%A5%E6%9C%AC');
same(decodeURI('%2f%23%3Aa%20b'), '%2f%23%3Aa b');
same(decodeURIComponent('%2f%23%3Aa%20b'), '/#:a b');
throwsName('URIError', () => encodeURI('\ud800'));
throwsName('URIError', () => decodeURIComponent('%ED%A0%80'));
throwsName('URIError', () => decodeURIComponent('%C0%80'));
same(escape('a😀 %'), 'a%uD83D%uDE00%20%25');
same(unescape('%uD83D%uDE00%zz'), '😀%zz');

same(Math.cbrt(-8), -2);
same(Math.acosh(1), 0);
same(Math.asinh(-0), -0);
same(Math.atanh(1), Infinity);
same(Math.atanh(2), NaN);
same(Math.cosh(0), 1);
same(Math.expm1(-0), -0);
same(Math.log1p(1e-20), 1e-20);
same(Math.sinh(-0), -0);
same(Math.tanh(Infinity), 1);
same(Math.f16round(1.00048828125), 1);
same(Math.f16round(-0), -0);

const cause = new TypeError('inner');
const error = new Error('outer', {cause});
same(error.cause, cause);
same(error.toString(), 'Error: outer');
same(Error.isError(error), true);
same(Error.isError({name: 'Error'}), false);
same(new SuppressedError(error, cause).suppressed, cause);
same(Object.getOwnPropertyDescriptor(error, 'cause').enumerable, false);
same(JSON.stringify({x: JSON.rawJSON('9007199254740993')}), '{"x":9007199254740993}');
same(JSON.isRawJSON(JSON.rawJSON('null')), true);
same(JSON.isRawJSON({rawJSON:'null'}), false);
throwsName('SyntaxError', () => JSON.rawJSON(' {}'));
throwsName('SyntaxError', () => JSON.rawJSON('[]'));

function target(a,b) { return [this.value, a, b, arguments.length]; }
const bound = target.bind({value: 1}, 2);
same(bound(3).join('/'), '1/2/3/2');
same(bound.length, 1);
same(bound.name, 'bound target');
same(target.call, bound.call);
same(target.toString(), 'function target(a,b) { return [this.value, a, b, arguments.length]; }');
same(Function.prototype.toString.call(target), target.toString());
function C(value) { this.value = value; this.target = (() => new.target)(); }
const Bound = C.bind(null, 7);
const instance = new Bound();
same(instance.value, 7);
same(instance.target, C);
same(instance instanceof Bound, true);
same(instance instanceof C, true);
const factorial = function self(x) { return x <= 1 ? 1 : x * self(x - 1); };
same(factorial(5), 120);
throwsName('ReferenceError', () => self(1));
throwsName('TypeError', () => {
  const immutable = 1;
  immutable = 2;
});

const contextSources = [];
const parsed = JSON.parse('{"big":9007199254740993,"negative":-0,"s":"\\u0061","old":[1],"old":3}', (key, value, context) => {
  if (key) contextSources.push(key + '=' + context.source);
  return value;
});
same(contextSources.join(','), 'big=9007199254740993,negative=-0,s="\\u0061",old=3');
same(parsed.negative, -0);
same(JSON.stringify(new Proxy([1, 2], {})), '[1,2]');

const prototype = {hidden: 1, kept: 2};
const inherited = Object.create(prototype, {hidden: {value: 2}});
inherited.first = 3;
inherited[4] = 4;
let keys = '';
for (const key in inherited) keys += key + ',';
same(keys, '4,first,kept,');
for (const key in null) keys += key;
same(keys, '4,first,kept,');
let loops = '';
outer: for (let i = 0; i < 3; i++) {
  for (const j of [1, 2, 3]) {
    if (i === 2) break outer;
    if (j === 2) continue outer;
    loops += i;
  }
}
same(loops, '01');
skip: {
  debugger;
  break skip;
  loops += 'unreachable';
}
same(loops, '01');
let first, remaining, named;
const targetObject = {};
const assigned = [5, 6, 7];
same(([first, ...remaining] = assigned), assigned);
same(first, 5);
same(remaining.join(','), '6,7');
({a: targetObject.slot, b: named = 8} = {a: 7});
same(targetObject.slot, 7);
same(named, 8);
for ([first] of [[2], [9]]) {}
same(first, 9);

let lastStrings;
const tagger = {
  marker: ':',
  tag(strings, value) {
    same(this, tagger);
    same(Object.isFrozen(strings), true);
    same(Object.isFrozen(strings.raw), true);
    if (lastStrings) same(lastStrings, strings);
    lastStrings = strings;
    return strings.raw[0] + this.marker + value;
  },
};
function callTag(value) { return tagger.tag`A\n${value}Z`; }
same(callTag(3), 'A\\n:3');
same(callTag(4), 'A\\n:4');
same(String.raw`A\n${2}Z`, 'A\\n2Z');
same((strings => strings[0])`\unicode`, undefined);

(async () => {
  same((await Array.fromAsync([Promise.resolve(1), 2], async n => n * 2)).join('/'), '2/4');
  same((await Array.fromAsync({0: Promise.resolve(7), length: 1}))[0], 7);
  async function* producer() { yield 4; yield 5; }
  same((await Array.fromAsync(producer())).join('/'), '4/5');
  console.log('standard built-ins: ' + checks + ' checks');
  $DONE();
})().catch($DONE);
