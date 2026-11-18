import { events } from './state.mjs';
events.push('module:start');
await using resource = {
  async [Symbol.asyncDispose]() {
    await 0;
    events.push('module:cleanup');
  },
};
export const ready = true;
