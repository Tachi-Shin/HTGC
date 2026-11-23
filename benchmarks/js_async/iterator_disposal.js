function* numbers() {
  try { yield* [1, 2, 3, 4]; } finally { console.log('closed'); }
}
const source = numbers();
const helper = source.drop(1).flatMap((x, i) => [x, i]).filter(x => x > 1).take(2);
console.log(source instanceof Iterator, Iterator.from(source) === source);
const array = [1].values();
console.log(Object.getPrototypeOf(Object.getPrototypeOf(array)) === Iterator.prototype,
            array.next === [2].values().next);
console.log([...Iterator.from('\ud800💡')].map(x => x.charCodeAt(0)).join(','));
console.log(JSON.stringify('x1x2'.matchAll(/x\d/g).map(m => m[0]).toArray()));
console.log(JSON.stringify(new Uint8Array([2, 3]).values().map(x => x + 1).toArray()));
console.log(JSON.stringify(helper.toArray()), helper.next().done);
console.log(Iterator.from('a💡').reduce((n, ch) => n + ch.length, 0));
console.log([1, 2, 3].keys().some(x => x === 1), [1, 2].values().every(x => x > 0));
console.log(JSON.stringify([...new Set([2]).values().map(x => x * 2)]));
console.log(Iterator.from({ next() { return { done: true }; } }).find(() => true));
class Counter extends Iterator {
  count = 0;
  next() { return { value: ++this.count, done: false }; }
}
console.log(JSON.stringify(new Counter().map(x => x * 2).take(2).toArray()));
try {
  Iterator.prototype.map.call({
    next() { throw 'unused'; },
    return() { console.log('invalid callback closed'); throw 'ignored'; },
  }, null);
} catch (error) { console.log(error.name); }

function resource(name, fail = false) {
  return { [Symbol.dispose]() {
    console.log(name);
    if (fail) throw name;
  } };
}
try {
  using first = resource('first', true), second = resource('second', true);
  throw null;
} catch (error) {
  console.log(error instanceof SuppressedError, error.error,
              error.suppressed.error, error.suppressed.suppressed === null);
}

function returned() { using r = resource('return cleanup'); return 7; }
console.log(returned());
let visits = 0;
for (using x of [resource('continue cleanup'), resource('break cleanup')]) {
  if (visits++ === 0) continue;
  console.log(typeof x);
  break;
}
let index = 0;
for (using x = resource('for cleanup'); index < 2; index++) {
  if (index === 0) continue;
  switch (index) {
    case 1: {
      using inner = resource('switch cleanup');
      break;
    }
  }
}
function* loan() {
  using r = resource('generator cleanup');
  yield 1;
}
const loaned = loan();
console.log(loaned.next().value, loaned.return(4).value);

const stack = new DisposableStack();
stack.use(resource('use cleanup'));
stack.adopt('adopt cleanup', value => console.log(value));
stack.defer(() => console.log('defer cleanup'));
const moved = stack.move();
console.log(stack.disposed, moved.disposed);
stack.dispose();
moved[Symbol.dispose]();
moved.dispose();
try { moved.defer(() => {}); } catch (error) { console.log(error.name); }

async function main() {
  let count = 1;
  for (await using r of [{
    async [Symbol.asyncDispose]() { await 0; console.log('for await using', count++); },
  }]) {
    continue;
  }
  const stack = new AsyncDisposableStack();
  stack.defer(async () => { await 0; console.log('async defer'); });
  stack.use(resource('sync fallback'));
  {
    await using empty = null;
    await using managed = stack;
    console.log('async block');
  }
  console.log(stack.disposed);
  async function* loan() {
    await using r = { async [Symbol.asyncDispose]() { await 0; console.log('async loan cleanup'); } };
    yield 2;
  }
  const loaned = loan();
  console.log((await loaned.next()).value);
  console.log((await loaned.return(5)).value);
}
main().then(() => $DONE(), $DONE);
