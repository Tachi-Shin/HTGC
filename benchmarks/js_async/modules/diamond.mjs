import { left } from './left.mjs';
import { right } from './right.mjs';
import { events } from './state.mjs';
events.push('diamond');
export const answer = left + right;
