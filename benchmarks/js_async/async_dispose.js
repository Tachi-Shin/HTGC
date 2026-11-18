async function* stream() {
  try { yield 3; } finally { console.log('closed'); }
}
async function main() {
  const source = stream();
  console.log((await source.next()).value);
  console.log(await source[Symbol.asyncDispose]() === undefined);
  console.log((await source.next()).done);
  const proto = Object.getPrototypeOf(Object.getPrototypeOf(Object.getPrototypeOf(stream())));
  const dispose = proto[Symbol.asyncDispose];
  console.log(await dispose.call({return() { return 5; }}) === undefined);
  const value = {return() { throw 'failed'; }};
  console.log(await dispose.call(value).catch(error => error));
}
main().then(() => $DONE(), $DONE);
