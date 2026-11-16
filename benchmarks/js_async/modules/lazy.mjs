import { runLazy } from './state.mjs';
runLazy();
await Promise.resolve();
export let count = 1;
export function increment() { count++; }
