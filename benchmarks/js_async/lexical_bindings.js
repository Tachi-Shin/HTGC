let outer = 'outer';
function test() {
  console.log(typeof doesNotExist, typeof NaN, typeof Infinity);
  try { console.log(outer); } catch (error) { console.log(error.name); }
  let outer = 'inner';
  console.log(outer);
  {
    try { console.log(typeof value); } catch (error) { console.log(error.name); }
    const value = 3;
    console.log(value);
  }
  {
    try { new Item(); } catch (error) { console.log(error.name); }
    class Item {}
    console.log(typeof Item);
  }
  switch (1) {
    case 1:
      try { console.log(block); } catch (error) { console.log(error.name); }
      break;
    case 2:
      let block = 'late';
  }
  try { for (let i = i; false;) {} } catch (error) { console.log(error.name); }
}
test();
console.log(outer);
const callbacks = [];
for (let i = 0; i < 3; i++) callbacks.push(() => i);
console.log(callbacks.map(callback => callback()).join(','));
const initCallbacks = [];
for (let i = (initCallbacks.push(() => i), 0); i < 2; (initCallbacks.push(() => i), i++)) {
  initCallbacks.push(() => i);
}
console.log(initCallbacks.map(callback => callback()).join(','));

function* closureGenerator() {
  for (let i = 0; i < 3; i++) yield () => i;
}
console.log([...closureGenerator()].map(callback => callback()).join(','));
let collection = [1];
try { for (let collection of collection) {} } catch (error) { console.log(error.name); }
try { for (const collection in collection) {} } catch (error) { console.log(error.name); }
let x = 9;
try { for (let [x = x] of [[]]) {} } catch (error) { console.log(error.name); }
function* checkGeneratorTdz() {
  try { for (let collection of collection) {} } catch (error) { yield error.name; }
}
console.log(checkGeneratorTdz().next().value);
async function checkAsync() {
  const functions = [];
  for (let i = 0; await Promise.resolve(i < 3); i = await Promise.resolve(i + 1)) {
    functions.push(() => i);
    if (i === 1) continue;
  }
  console.log(functions.map(callback => callback()).join(','));
}
checkAsync().then(() => $DONE(), $DONE);
