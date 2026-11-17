const target = {value: 42};
const ref = new WeakRef(target);
console.log(ref.deref() === target, ref.deref().value, ref instanceof WeakRef);
const symbol = Symbol('target');
console.log(new WeakRef(symbol).deref() === symbol);
for (const value of [undefined, null, 1, 'x', Symbol.for('global')]) {
  try { new WeakRef(value); } catch (error) { console.log(error.name); }
}
try { WeakRef(target); } catch (error) { console.log(error.name); }
const token = {};
const registry = new FinalizationRegistry(value => console.log(value));
console.log(registry.register(target, 'held', token));
console.log(registry.register({}, 'other', token));
console.log(registry.unregister(token), registry.unregister(token));
try { registry.register(target, target); } catch (error) { console.log(error.name); }
try { registry.register(target, 'held', 1); } catch (error) { console.log(error.name); }
try { registry.unregister(null); } catch (error) { console.log(error.name); }
try { new FinalizationRegistry(null); } catch (error) { console.log(error.name); }
class Child extends WeakRef {}
console.log(new Child(target).deref() === target, new Child(target) instanceof Child);
$DONE();
