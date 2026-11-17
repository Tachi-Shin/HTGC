let checks = 0;
function eq(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('atomics check ' + checks + ': ' + actual + ' != ' + expected);
}
function throwsTypeError(f) {
  let name = '';
  try { f(); } catch (error) { name = error.name; }
  eq(name, 'TypeError');
}
function throwsRangeError(f) {
  let name = '';
  try { f(); } catch (error) { name = error.name; }
  eq(name, 'RangeError');
}

(async () => {
  const buffer = new SharedArrayBuffer(8, {maxByteLength: 24});
  const signed = new Int32Array(buffer);
  const view = new DataView(buffer);
  eq(buffer.growable, true);
  eq(buffer.maxByteLength, 24);
  eq(Object.prototype.toString.call(buffer), '[object SharedArrayBuffer]');
  eq(ArrayBuffer.isView(view), true);
  eq(Atomics.store(signed, 0, 4294967295.25), 4294967295);
  eq(Atomics.load(signed, 0), -1);
  eq(Atomics.compareExchange(signed, 0, 4294967295, 7), -1);
  eq(Atomics.add(signed, 0, 6), 7);
  eq(Atomics.sub(signed, 0, 2), 13);
  eq(Atomics.and(signed, 0, 3), 11);
  eq(Atomics.or(signed, 0, 8), 3);
  eq(Atomics.xor(signed, 0, 3), 11);
  eq(Atomics.exchange(signed, 0, 0), 8);

  const big = new BigUint64Array(buffer);
  eq(Atomics.store(big, 0, -1n), -1n);
  eq(Atomics.add(big, 0, 2n), 18446744073709551615n);
  eq(Atomics.load(big, 0), 1n);
  throwsTypeError(() => Atomics.store(big, 0, 1));
  throwsTypeError(() => Atomics.load(new Float64Array(2), 0));
  throwsRangeError(() => Atomics.load(signed, 2));
  throwsTypeError(() => Atomics.waitAsync(new Int32Array(1), 0, 0));
  eq(Atomics.notify(new Int32Array(1), 0), 0);
  eq(Atomics.isLockFree(4), true);
  eq(Atomics.isLockFree(3), false);
  eq(Atomics.pause(0), undefined);
  throwsTypeError(() => Atomics.pause('1'));
  throwsTypeError(() => ArrayBuffer.prototype.transfer.call(buffer));
  throwsTypeError(() => SharedArrayBuffer.prototype.slice.call(new ArrayBuffer(8)));

  buffer.grow(16);
  eq(buffer.byteLength, 16);
  eq(view.byteLength, 16);
  eq(signed.length, 4);
  eq(Atomics.load(big, 0), 1n);
  eq(Atomics.load(big, 1), 0n);
  throwsRangeError(() => buffer.grow(8));
  throwsRangeError(() => buffer.grow(25));
  const copy = buffer.slice(0, 8);
  eq(copy instanceof SharedArrayBuffer, true);
  eq(new BigUint64Array(copy)[0], 1n);
  Atomics.store(big, 0, 0n);
  eq(new BigUint64Array(copy)[0], 1n);

  eq(Atomics.waitAsync(signed, 1, 1).value, 'not-equal');
  const zero = Atomics.waitAsync(signed, 1, 0, 0);
  eq(zero.async, false);
  eq(zero.value, 'timed-out');
  const first = Atomics.waitAsync(signed, 1, 0);
  const second = Atomics.waitAsync(signed, 1, 0);
  eq(first.async, true);
  const byteOffsetView = new Int32Array(buffer, 4, 1);
  eq(Atomics.notify(byteOffsetView, 0, 1), 1);
  eq(await first.value, 'ok');
  eq(Atomics.notify(byteOffsetView, 0), 1);
  eq(await second.value, 'ok');
  eq(await Atomics.waitAsync(signed, 1, 0, 2).value, 'timed-out');
  eq(Atomics.notify(signed, 1), 0);
  console.log('atomics: ' + checks + ' checks');
  $DONE();
})().catch($DONE);
