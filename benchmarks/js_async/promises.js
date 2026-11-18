function equal(actual, expected) {
  if (actual !== expected) throw new Error('expected ' + expected + ', got ' + actual);
}
const order = [];
async function simple() {
  order.push('start');
  const value = await 3;
  order.push(value);
  return 5;
}
simple().then(value => order.push(value));
Promise.resolve().then(() => order.push('microtask'));
order.push('sync');

async function checks() {
  equal(await Promise.resolve(7), 7);
  await 0;
  equal(order.join(','), 'start,sync,3,microtask,5');
  const pending = Promise.withResolvers();
  const adopted = new Promise((resolve, reject) => {
    resolve(pending.promise);
    reject('ignored');
  });
  pending.resolve(11);
  pending.reject('also ignored');
  equal(await adopted, 11);
  const thenable = { then(resolve, reject) { resolve(9); reject(10); throw 11; } };
  equal(await thenable, 9);
  equal(await Promise.resolve(thenable), 9);
  try { await Promise.reject(null); throw 'not rejected'; } catch (error) { equal(error, null); }
  try { await Promise.reject(undefined); throw 'not rejected'; } catch (error) { equal(error, undefined); }
  async function caught() { try { return 12; } catch { return 13; } }
  async function replace() { try { return 12; } finally { await 1; return 14; } }
  async function cleanup() { try { return 12; } finally { throw 'cleanup'; } }
  equal(await caught(), 12);
  equal(await replace(), 14);
  equal(await cleanup().catch(error => error), 'cleanup');
  equal(await Promise.resolve(3).finally(() => Promise.resolve(4)), 3);
  equal(await Promise.reject(3).finally(() => 4).catch(error => error), 3);
  equal(await Promise.resolve(3).finally(() => { throw 4; }).catch(error => error), 4);
  const cycle = Promise.withResolvers();
  cycle.resolve(cycle.promise);
  equal(await cycle.promise.catch(error => error.name), 'TypeError');
  let chained;
  chained = Promise.resolve().then(() => chained);
  equal(await chained.catch(error => error.name), 'TypeError');
  equal((await Promise.all([Promise.resolve(1), 2, thenable])).join(','), '1,2,9');
  equal((await Promise.all([])).length, 0);
  const settled = await Promise.allSettled([Promise.resolve(1), Promise.reject('bad')]);
  equal(settled[0].status, 'fulfilled'); equal(settled[0].value, 1);
  equal(settled[1].status, 'rejected'); equal(settled[1].reason, 'bad');
  equal(await Promise.race([Promise.resolve(2), Promise.resolve(3)]), 2);
  equal(await Promise.any([Promise.reject(2), Promise.resolve(3)]), 3);
  equal(await Promise.any([Promise.reject(2), Promise.reject(3)]).catch(error => error.errors.join(',')), '2,3');
  equal(await Promise.any([]).catch(error => error.name), 'AggregateError');
  equal(await Promise.try((a, b) => a + b, 3, 4), 7);
  equal(await Promise.try(() => { throw 8; }).catch(error => error), 8);
  let value = 10;
  value += await Promise.resolve(2);
  equal(value, 12);
  value ||= await Promise.reject('must not execute');
  equal(value, 12);
  equal(false && await Promise.reject('must not execute'), false);
  equal(true || await Promise.reject('must not execute'), true);
  equal(null ?? await Promise.resolve(15), 15);
  equal((value = 2, await Promise.resolve(value + 3)), 5);
  let loops = 0;
  for (let i = 0; i < await Promise.resolve(3); i += await 1) {
    if (i === 1) continue;
    loops += await 1;
  }
  equal(loops, 2);
  const altered = Promise.resolve(1);
  altered.then = (resolve, reject) => { resolve(2); reject(3); resolve(4); };
  equal(await Promise.all([altered]).catch(error => error), 3);
  const statuses = await Promise.allSettled([altered]);
  equal(statuses[0].status, 'fulfilled'); equal(statuses[0].value, 2);
  let called = false;
  try { Promise(() => {}); } catch (error) { called = error.name === 'TypeError'; }
  equal(called, true);
  const direct = Promise.resolve(2);
  equal(direct.then === Promise.prototype.then, true);
  equal(await Promise.prototype.then.call(direct, value => value + 1), 3);
  direct.constructor = {};
  equal(Promise.resolve(direct) === direct, false);
  equal(await Promise.resolve(direct), 2);
  let touched = 0;
  const accessor = { get then() { touched++; throw 'getter'; } };
  equal(await Promise.resolve(accessor).catch(error => error), 'getter');
  equal(touched, 1);
  const receiver = { number: 18, get method() {
    order.push('get'); return function (arg) { return this.number + arg; };
  }};
  async function argument() { order.push('arg'); return 1; }
  equal(await receiver.method(await argument()), 19);
  equal(order.slice(-2).join(','), 'get,arg');
  const absent = null;
  equal(absent?.[await Promise.reject('computed key')], undefined);
  equal(absent?.[touched++]?.(await Promise.reject('call argument')), undefined);
  equal(touched, 1);
  class P extends Promise {}
  const p = P.resolve(4);
  equal(p instanceof P, true);
  equal(P.resolve(p), p);
  equal(Promise.resolve(p) === p, false);
  equal(p.then(v => v + 1) instanceof P, true);
  equal(p.finally(() => 1) instanceof P, true);
  for (const value of [P.all([p]), P.allSettled([p]), P.any([p]), P.race([p]), P.try(() => 5)]) {
    equal(value instanceof P, true);
    await value;
  }
  const kit = P.withResolvers();
  kit.resolve(7);
  equal(kit.promise instanceof P, true);
  equal(await kit.promise, 7);
  class NativeChain extends P { static get [Symbol.species]() {return Promise;} }
  const chain = NativeChain.resolve(5).finally(() => p);
  equal(chain instanceof NativeChain, false);
  equal(await chain, 5);
  const receivers = [];
  class Counting extends P {
    static get resolve() { receivers.push("get"); return function(v) { receivers.push(this === Counting); return P.resolve(v); }; }
  }
  equal((await Counting.all([1, 2])).join(":"), "1:2");
  equal(receivers.join(","), "get,true,true");
  function Alternative(executor) {
    executor(v => {this.value = v}, e => {this.error = e});
  }
  const custom = Promise.resolve.call(Alternative, 9);
  equal(custom instanceof Alternative, true);
  equal(custom.value, 9);
  class Exotic extends P { static get [Symbol.species]() {return Alternative;} }
  const other = Exotic.resolve(2).then(n => n * 2);
  equal(other instanceof Alternative, true);
  await 0;
  equal(other.value, 4);
  const badSpecies = P.resolve(1);
  badSpecies.constructor = {[Symbol.species]: {}};
  try { badSpecies.then(); throw 'expected TypeError'; } catch (e) { equal(e.name, 'TypeError'); }
  console.log('promises: pass');
}
checks().then(() => $DONE(), error => $DONE(error));
