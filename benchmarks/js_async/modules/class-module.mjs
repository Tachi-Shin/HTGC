export const key = "method";
class Base { value() { return 12; } }
export default class extends (await Promise.resolve(Base)) {
  [await Promise.resolve(key)]() { return super.value(); }
}
