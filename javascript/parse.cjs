const fs = require('node:fs');
const acorn = require('acorn');
try {
  const input = fs.readFileSync(0, 'utf8');
  // Direct eval may inherit a function's new.target binding.
  const newTarget = process.argv.includes('--eval-new-target');
  const superProperty = process.argv.includes('--eval-super');
  const superCall = process.argv.includes("--eval-super-call");
  const privateNames = process.argv.filter(arg => arg.startsWith("--eval-private=")).map(arg => arg.slice("--eval-private=".length));
  const fieldEval = process.argv.includes('--eval-class-field');
  const parser = newTarget || superProperty || superCall || fieldEval
    ? acorn.Parser.extend(Base => class extends Base {
        get allowNewDotTarget() { return super.allowNewDotTarget || newTarget; }
        checkUnreserved(identifier) {
          if (fieldEval && identifier.name === 'arguments' &&
              this.currentThisScope() === this.scopeStack[0]) {
            this.raise(identifier.start, "Cannot use 'arguments' in class field eval");
          }
          super.checkUnreserved(identifier);
        }
        get allowDirectSuper() {
          return super.allowDirectSuper || (superCall && this.currentThisScope() === this.scopeStack[0]);
        }
        get allowSuper() {
          return super.allowSuper || (superProperty && this.currentThisScope() === this.scopeStack[0]);
        }
      })
    : acorn.Parser;
  const instance = new parser({ecmaVersion: 'latest', sourceType: process.argv.includes('--script') ? 'script' : 'module', locations: true}, input);
  if (privateNames.length) {
    const declared = instance.enterClassBody();
    for (const name of privateNames) declared[name] = true;
  }
  const ast = instance.parse();
  if (privateNames.length) instance.exitClassBody();
  if (process.argv.includes('--syntax-only')) process.exit(0);
  function rewriteUnicodeSets(pattern, flags) {
    return require('regexpu-core')(pattern, flags, {
      unicodeSetsFlag: 'transform',
      unicodePropertyEscapes: 'transform',
    });
  }
  function lowerUnicodeSets(node) {
    if (!node || typeof node !== 'object') return;
    if (['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression', 'ClassDeclaration', 'ClassExpression'].includes(node.type)) {
      node.htgcSource ??= input.slice(node.start, node.end);
    } else if (node.type === 'MethodDefinition' ||
               (node.type === 'Property' && (node.method || node.kind === 'get' || node.kind === 'set'))) {
      const start = node.type === 'MethodDefinition' && node.static
        ? node.key.start - (node.computed ? 1 : 0)
        : node.start;
      // Static methods exclude the static modifier, including any trivia.
      const source = input.slice(node.start, node.end);
      node.value.htgcSource = node.type === 'MethodDefinition' && node.static
        ? source.replace(/^static(?:\s|\/\*[\s\S]*?\*\/|\/\/[^\r\n]*(?:\r\n|\r|\n))*/, '')
        : input.slice(start, node.end);
    }
    if (node.regex?.flags.includes('v')) {
      try {
        node.regex.lowered = rewriteUnicodeSets(node.regex.pattern, node.regex.flags);
      } catch (error) {
        throw new SyntaxError(`${node.loc.start.line}:${node.loc.start.column + 1}: ${error.message}`);
      }
    }
    if ((node.type === 'CallExpression' || node.type === 'NewExpression') &&
        !node.optional && node.callee.type === 'Identifier' &&
        node.callee.name === 'RegExp') {
      const [pattern, flags] = node.arguments;
      if (pattern?.type === 'Literal' && typeof pattern.value === 'string' &&
          flags?.type === 'Literal' && typeof flags.value === 'string' &&
          flags.value.includes('v') && !flags.value.includes('u')) {
        try {
          node.htgcLoweredRegExp = rewriteUnicodeSets(pattern.value, flags.value);
        } catch (error) {
          // Invalid patterns are observable only if this call reaches the
          // intrinsic constructor. Preserve its runtime SyntaxError.
          if (!(error instanceof SyntaxError)) throw error;
        }
      }
    }
    for (const child of Object.values(node)) lowerUnicodeSets(child);
  }
  lowerUnicodeSets(ast);
  // Acorn keeps the exact spelling in Literal.bigint; JSON has no BigInt value.
  process.stdout.write(JSON.stringify(ast, (_, value) => typeof value === 'bigint' ? null : value));
} catch (error) {
  process.stderr.write(error.message + '\n');
  process.exitCode = error instanceof SyntaxError ? 2 : 1;
}
