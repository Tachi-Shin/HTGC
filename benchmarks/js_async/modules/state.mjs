export const events = [];
export let lazyRuns = 0;
export let failures = 0;
export function runLazy() { lazyRuns++; }
export function runFailure() { failures++; }
