import { readCycle } from './module_cycle.js';

const log = document.getElementById('module-log');
log.setAttribute('data-runs', log.getAttribute('data-runs') + '1');

export let count = 1;
export default function increment() {
  return ++count;
}
export { readCycle };
