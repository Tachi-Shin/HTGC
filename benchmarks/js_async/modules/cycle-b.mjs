import { value } from './cycle-a.mjs';
await Promise.resolve();
export function readA() { return value; }
