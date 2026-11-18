function eq(a, b) { if (!Object.is(a, b)) throw new Error(a + " != " + b); }

class Base { inherited() { return 2; } }
const order = [];
function* steps() {
  class Derived extends (yield "base") {
    [yield "field"] = this.inherited();
    [yield "method"]() { return this.field + 1; }
    static [yield "static"] = 4;
    static { order.push(this.total); }
  }
  return Derived;
}
const task = steps();
eq(task.next().value, "base");
eq(task.next(Base).value, "field");
eq(task.next("field").value, "method");
eq(task.next("value").value, "static");
eq(order.length, 0);
const result = task.next("total");
eq(result.done, true);
eq(order.join(), "4");
eq(new result.value().value(), 3);

async function build(skip) {
  class Derived extends (skip ? Base : await Promise.resolve(Base)) {
    [skip ? "method" : await Promise.resolve("method")]() { return super.inherited(); }
    static { order.push("static"); }
  }
  return Derived;
}
const immediate = build(true);
eq(order.join(), "4,static");
const pending = build(false);
eq(order.join(), "4,static");

async function verify() {
  const first = await immediate;
  const second = await pending;
  eq(new first().method(), 2);
  eq(new second().method(), 2);
  eq(order.join(), "4,static,static");
  let error;
  try { class Bad extends (await Promise.reject("bad base")) {} }
  catch (thrown) { error = thrown; }
  eq(error, "bad base");
  const jobs = [];
  async function defineClass() {
    class WithAwait extends (await Promise.resolve(Base)) {
      static { jobs.push("static"); }
    }
    jobs.push("after");
    return WithAwait;
  }
  const defined = defineClass();
  Promise.resolve().then(() => jobs.push("queued"));
  await defined;
  eq(jobs.join(), "static,after,queued");
  console.log("class suspension: pass");
}
verify().then(() => $DONE(), error => $DONE(error));
