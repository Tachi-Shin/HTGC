let checks = 0;
function eq(actual, expected) {
  checks++;
  if (!Object.is(actual, expected)) throw new Error('Unicode sets check ' + checks + ': ' + actual + ' != ' + expected);
}

const letters = /[\p{ASCII}&&\p{Letter}]/v;
eq(letters.test('A'), true);
eq(letters.test('Å'), false);
eq(letters.test('1'), false);
eq(letters.source, '[\\p{ASCII}&&\\p{Letter}]');
eq(letters.unicode, false);
eq(letters.unicodeSets, true);
eq(letters.flags, 'v');
eq(/[\p{Script_Extensions=Greek}--[πμ]]/v.test('λ'), true);
eq(/[\p{Script_Extensions=Greek}--[πμ]]/v.test('π'), false);
eq(/[a--A]/iv.test('A'), false);
eq(/[\q{abc|ab|a}]c/v.exec('abc')[0], 'abc');
eq(/[\q{abc|ab|a}--\q{ab}]/v.exec('ab')[0], 'a');
eq(/[\p{RGI_Emoji_Flag_Sequence}]/v.exec('x🇯🇵z')[0], '🇯🇵');
const pattern = /(?<match>[\q{ab|a}])/dgv;
const matches = [...'xab a'.matchAll(pattern)];
eq(matches.map(match => match.groups.match).join(','), 'ab,a');
eq(matches[0].indices.groups.match.join(','), '1,3');
eq(pattern.lastIndex, 0);
eq('abc'.replaceAll(pattern, '<$<match>>'), '<ab>c');
eq('a😀b'.split(/(?:)/v).join(','), 'a,😀,b');
eq([...('😀'.matchAll(/(?:)/gv))].map(match => match.index).join(','), '0,2');
eq(new RegExp(letters).test('X'), true);
eq(new RegExp(letters, 'vg').test('é'), false);
const compiled = /x/;
compiled.compile(letters);
eq(compiled.unicodeSets, true);
eq(compiled.test('D'), true);

eq(new RegExp('[[a-z]--[aeiou]]', 'v').test('z'), true);
eq(RegExp('[[a-z]--[aeiou]]', 'v').test('a'), false);
function shadow(RegExp) { return RegExp('[a--b]', 'v'); }
eq(shadow((pattern, flags) => pattern + flags), '[a--b]v');
let caught = '';
try { new RegExp('[[', 'v'); } catch (error) { caught = error.name; }
eq(caught, 'SyntaxError');
console.log('unicode sets: ' + checks + ' checks');
$DONE();
