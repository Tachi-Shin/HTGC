import { runFailure } from './state.mjs';
runFailure();
await Promise.resolve();
throw null;
