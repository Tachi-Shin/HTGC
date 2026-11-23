import value from './value.json' with { type: 'json' };
await using resource = { async [Symbol.asyncDispose]() {} };
const more = await import('./value.json', {with: {type: 'json'}});
document.getElementById('status').textContent = `${value.label.normalize('NFC')}:${more.default.n}`;
