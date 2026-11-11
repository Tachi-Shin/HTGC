const fs = require('node:fs');
const acorn = require('acorn');
try {
  const input = fs.readFileSync(0, 'utf8');
  const ast = acorn.parse(input, {ecmaVersion: 'latest', sourceType: 'module', locations: true});
  process.stdout.write(JSON.stringify(ast));
} catch (error) {
  process.stderr.write(error.message + '\n');
  process.exitCode = 1;
}
