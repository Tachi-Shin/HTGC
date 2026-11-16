import { readA } from './cycle-b.mjs';
await Promise.resolve();
export const value = 5;
export function readCycle() { return readA(); }
