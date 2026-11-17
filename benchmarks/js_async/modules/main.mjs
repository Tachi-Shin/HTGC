import { events, lazyRuns, failures } from './state.mjs';
import { answer } from './diamond.mjs';
import { readCycle } from './cycle-a.mjs';
import config from './config.json' with { type: 'json' };
function equal(actual, expected) {
  if (actual !== expected) throw new Error('expected ' + expected + ', got ' + actual);
}
equal(answer, 42);
equal(readCycle(), 5);
equal(events.join(','), 'left:start,right:start,left:end,right:end,diamond');
equal(lazyRuns, 0);
const [first, second] = await Promise.all([import('./lazy.mjs'), import('./lazy.mjs')]);
equal(first === second, true);
equal(lazyRuns, 1);
first.increment();
equal(second.count, 2);
const name = './lazy.mjs';
equal(await import(name) === first, true);
for (let i = 0; i < 2; i++) {
  try { await import('./failure.mjs'); throw 'not rejected'; } catch (error) { equal(error, null); }
  try { await import('./sync-failure.mjs'); throw 'not rejected'; } catch (error) { equal(error, undefined); }
}
equal(failures, 1);
equal(await import('./missing.mjs').catch(() => 'missing'), 'missing');
equal(config.label, '設定');
equal(config.nested.enabled, true);
equal((await import('./config.json', { with: { type: 'json' } })).default, config);
equal(await import('./config.json').catch(error => error instanceof TypeError), true);
equal(await import('./config.json', { with: { type: true } }).catch(error => error instanceof TypeError), true);
const meta = import.meta;
equal(meta, import.meta);
equal(Object.getPrototypeOf(meta), null);
equal(meta.url.endsWith('/main.mjs'), true);
meta.testKey = 7;
equal(import.meta.testKey, 7);
const cleanup = await import('./cleanup.mjs');
equal(cleanup.ready, true);
equal(events.slice(-2).join(','), 'module:start,module:cleanup');
console.log('modules: pass');
