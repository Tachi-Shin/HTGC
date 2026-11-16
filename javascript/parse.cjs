const fs = require('node:fs');
const acorn = require('acorn');
try {
  const input = fs.readFileSync(0, 'utf8');
  const ast = acorn.parse(input, {ecmaVersion: 'latest', sourceType: 'module', locations: true});
  // Acorn keeps the exact spelling in Literal.bigint; JSON has no BigInt value.
  process.stdout.write(JSON.stringify(ast, (_, value) => typeof value === 'bigint' ? null : value));
} catch (error) {
  process.stderr.write(error.message + '\n');
  process.exitCode = 1;
}
