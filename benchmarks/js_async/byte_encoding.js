let checks = 0;
function same(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('byte check ' + checks + ': ' + String(actual) + ' != ' + String(expected));
}
function assertThrows(name, body) {
  let actual = '';
  try { body(); } catch (error) { actual = error.name; }
  same(actual, name);
}

const bytes = Uint8Array.fromHex('0aBFFF');
same(bytes.toHex(), '0abfff');
same(bytes.toBase64(), 'Cr//');
same(bytes.toBase64({alphabet: 'base64url'}), 'Cr__');
same(bytes.subarray(0, 2).toBase64({omitPadding: true}), 'Cr8');
same(Uint8Array.fromBase64(' Cr_ _ ', {alphabet: 'base64url'}).toHex(), '0abfff');
same(Uint8Array.fromBase64('Zg').toHex(), '66');
same(Uint8Array.fromBase64('Zg==',{lastChunkHandling:'strict'}).toHex(), '66');
same(Uint8Array.fromBase64('Zm9vYg', {lastChunkHandling:'stop-before-partial'}).toHex(), '666f6f');
assertThrows('SyntaxError', () => Uint8Array.fromBase64('Zh==',{lastChunkHandling:'strict'}));
assertThrows('SyntaxError', () => Uint8Array.fromBase64('Z'));
assertThrows('SyntaxError', () => Uint8Array.fromBase64('Zm9v='));
assertThrows('SyntaxError', () => Uint8Array.fromHex('0'));
assertThrows('TypeError', () => Uint8Array.fromHex(0));
assertThrows('TypeError', () => Uint8Array.fromBase64('AA==', null));
assertThrows('TypeError', () => Uint8Array.prototype.toHex.call(new Uint8ClampedArray(1)));
const input = new Uint8Array(5);
const result = input.subarray(1, 4).setFromBase64(' Zm9v  YmFy ');
same(result.read, 5);
same(result.written, 3);
same(input.toHex(), '00666f6f00');
const short = input.subarray(1, 2);
same(short.setFromBase64('Zm9v').written, 0);
same(short.setFromBase64('Yg==').written, 1);
same(input[1], 98);
assertThrows('SyntaxError', () => input.setFromHex('22zz'));
same(input[0], 34);
assertThrows('SyntaxError', () => input.setFromBase64('YWJj@'));
same(input.subarray(0, 3).toHex(), '616263');

const map = new Map();
same(map.getOrInsert('x', null), null);
same(map.getOrInsert('x', 1), null);
same(map.getOrInsertComputed(-0, key => Object.is(key, 0)), true);
same(map.getOrInsertComputed('a', key => {
  map.set(key, 'nested');
  return 'computed';
}), 'computed');
same(map.get('a'), 'computed');
assertThrows('TypeError', () => map.getOrInsertComputed('a', 1));
const weak = new WeakMap();
const key = {};
same(weak.getOrInsert(key, null), null);
same(weak.getOrInsertComputed(key, () => 3), null);
same(weak.getOrInsertComputed({}, () => 4), 4);
assertThrows('TypeError', () => weak.getOrInsert(1, 2));

console.log('byte encoding and upsert: ' + checks + ' checks');
$DONE();
