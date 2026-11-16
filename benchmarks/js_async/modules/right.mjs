import { events } from './state.mjs';
events.push('right:start');
await Promise.resolve();
events.push('right:end');
export const right = 22;
