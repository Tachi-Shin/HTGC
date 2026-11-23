console.log(globalThis.globalThis === globalThis);
console.log(globalThis.Array === Array, globalThis.Math === Math);
globalThis.htgcTemporary = 1;
console.log(htgcTemporary);
htgcTemporary = 2;
console.log(globalThis.htgcTemporary);
Object.defineProperty(globalThis, 'htgcAccessor', {
  configurable: true,
  get() { return 12; },
  set(value) { globalThis.htgcTemporary = value; },
});
console.log(htgcAccessor);
htgcAccessor = 14;
console.log(globalThis.htgcTemporary);
{
  let htgcTemporary = 22;
  console.log(htgcTemporary, globalThis.htgcTemporary);
}
console.log(delete globalThis.htgcTemporary, typeof htgcTemporary);
try { htgcTemporary = 10; } catch (error) { console.log(error.name); }
console.log(delete globalThis.htgcAccessor);
console.log(typeof globalThis.NaN, typeof globalThis.Infinity, globalThis.undefined);
console.log(Object.getOwnPropertyDescriptor(globalThis, 'NaN').writable);
$DONE();
