let checks = 0;
function eq(a, b) {checks++; if (!Object.is(a, b)) throw new Error('check ' + checks + ': ' + String(a) + ' != ' + String(b));}
function error(fn, name) {let caught = ''; try {fn();} catch(e) {caught = e.name;} eq(caught, name);}
const parsed = JSON.parse('{"a":1,"b":[true,null,"日本語"],"__proto__":{"polluted":true}}');
eq(parsed.a, 1); eq(parsed.b[1], null); eq(parsed.b[2], '日本語');
eq(Object.getPrototypeOf(parsed), Object.prototype); eq(Object.hasOwn(parsed, '__proto__'), true);
eq(JSON.stringify({a: undefined, b: Symbol('s'), c() {}, d: NaN, e: Infinity}), '{"d":null,"e":null}');
eq(JSON.stringify([undefined, Symbol('s'), () => {}, NaN]), '[null,null,null,null]');
eq(JSON.stringify(undefined), undefined); eq(JSON.stringify(-0), '0');
eq(JSON.stringify({a: 1, b: {a: 2, c: 3}}, ['b', 'a', 'a']), '{"b":{"a":2},"a":1}');
eq(JSON.stringify({a: [1]}, null, 2), '{\n  "a": [\n    1\n  ]\n}');
eq(JSON.stringify({toJSON(key) {return 'key=' + key;}}), '"key="');
const calls = [];
const output = JSON.parse('{"a":1,"b":[2,3]}', function(key, value) {
  calls.push(key); if (key === '0') return undefined;
  return typeof value === 'number' ? value * 2 : value;
});
eq(calls.join(','), 'a,0,1,b,'); eq(output.a, 2); eq(output.b[1], 6);
eq(output.b.length, 2); eq(Object.hasOwn(output.b, '0'), false);
eq(JSON.stringify(output), '{"a":2,"b":[null,6]}');
const original = {a: 2};
eq(JSON.stringify(original, function(key, value) {if (key === 'a') {eq(this, original); return value + 1;} return value;}), '{"a":3}');
const cyclic = {}; cyclic.self = cyclic; error(() => JSON.stringify(cyclic), 'TypeError');
error(() => JSON.parse('{a:1}'), 'SyntaxError');
eq(JSON.stringify(Object(3)), '3'); eq(JSON.stringify(Object('hi')), '"hi"');
eq(JSON.stringify(Object(Symbol())), '{}');
const frozen = JSON.parse('{"a":1,"b":2}', function (key, value) {
  if (key === 'a') {Object.freeze(this); return 9;}
  return value;
});
eq(frozen.a, 1); eq(frozen.b, 2);
console.log('json: ' + checks + ' checks');
$DONE();
