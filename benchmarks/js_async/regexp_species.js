let checks = 0;
function same(actual, expected) {
  if (!Object.is(actual, expected)) throw new Error(actual + " != " + expected);
  checks++;
}

const names = "zbb".match(/(?<letter>a+)|(?<letter>b+)/d);
same(names.groups.letter, "bb");
same(names.indices.groups.letter, names.indices[2]);
same(names.indices.groups.letter.join(), "1,3");
same("z".match(/(?:(?<x>a)|(?<x>b))?z/d).indices.groups.x, undefined);

class TrackingRegExp extends RegExp {
  static get [Symbol.species]() {
    return class extends RegExp {
      constructor(source, flags) { super(source, flags); seen.push(flags); }
    };
  }
}
const seen = [];
const regex = new TrackingRegExp("(?<x>a)|(?<x>b)", "g");
same([..."aba".matchAll(regex)].map(match => match.groups.x).join(), "a,b,a");
same("xyaz".split(regex).join(), "xy,a,,z");
same(seen.join(), "g,gy");

const testRuntime = String.raw`return function (text) {
  const pattern = /(?<x>[(){}])|(?<x>\/)/d;
  const quotient = 60 / 3 / 2;
  const result = pattern.exec(text);
  return [result.groups.x, result.indices.groups.x[0], quotient];
};`;
const runtime = Function(testRuntime)();
same(runtime("c(").join(), "(,1,10");
same(runtime("z/").join(), "/,1,10");
const freshPattern = "return /a/g;";
const factory = Function(freshPattern + "");
same(factory() === factory(), false);

const log = [];
const stringMethod = { [Symbol.match](str) { log.push(str); return "called"; } };
const arbitraryReceiver = { toString() { throw new Error("unexpected conversion"); } };
same(String.prototype.match.call(arbitraryReceiver, stringMethod), "called");
same(log[0], arbitraryReceiver);

console.log("regexp species: " + checks + " checks");
$DONE();
