let checks=0;
function eq(a,b){checks++;if(!Object.is(a,b))throw new Error('regexp check '+checks+': '+String(a)+' != '+String(b));}
function error(f,name){let caught='';try{f();}catch(e){caught=e.name;}eq(caught,name);}
const re=/(?<word>a+)(b)?/dg;eq(re.flags,'dg');eq(re.source,'(?<word>a+)(b)?');
let m=re.exec('xaab aa');eq(m[0],'aab');eq(m[1],'aa');eq(m[2],'b');eq(m.index,1);eq(m.input,'xaab aa');eq(m.groups.word,'aa');eq(m.indices[0].join(','),'1,4');eq(m.indices[1].join(','),'1,3');eq(m.indices.groups.word,m.indices[1]);eq(re.lastIndex,4);
m=re.exec('xaab aa');eq(m[2],undefined);eq(m.indices[2],undefined);eq(m.index,5);eq(re.lastIndex,7);eq(re.exec('xaab aa'),null);eq(re.lastIndex,0);
const sticky=/a/y;sticky.lastIndex=1;eq(sticky.exec('ba').index,1);sticky.lastIndex=0;eq(sticky.exec('ba'),null);eq(sticky.lastIndex,0);
const plain=/a/;plain.lastIndex=9;eq(plain.test('a'),true);eq(plain.lastIndex,9);
eq(new RegExp('').source,'(?:)');eq(new RegExp('/\n').source,'\\/\\n');eq(RegExp(plain),plain);eq(new RegExp(plain)===plain,false);
error(()=>new RegExp('a','gg'),'SyntaxError');error(()=>new RegExp('['),'SyntaxError');error(()=>RegExp.prototype.exec.call({},'a'),'TypeError');
eq('a1a2'.match(/a/g).join(','),'a,a');eq('😀x'.match(/(?:)/gu).length,3);
eq('a1b2'.replace(/(\w)(\d)/g,'$2$1'),'1a2b');eq('abc'.replace(/b/,'[$`][$&][$\x27]'),'a[a][b][c]c');
eq('ab'.replace(/(?<x>a)b/,'$<x>!'),'a!');eq('ab'.replace(/(a)/,'$01$12'),'aa2b');
eq('a1a2'.replace(/a(\d)/g,(match,digit,pos)=>digit+':'+pos),'1:02:2');eq('aaa'.replaceAll('a','b'),'bbb');error(()=>'a'.replaceAll(/a/,'b'),'TypeError');
eq('a1b2'.split(/(\d)/).join(','),'a,1,b,2,');eq('abc'.split(/(?:)/).join(','),'a,b,c');eq('😀x'.split(/(?:)/u).join(','),'😀,x');eq('abc'.split(/b/,1).join(','),'a');
eq('abc'.search(/b/),1);sticky.lastIndex=5;eq('ba'.search(sticky),-1);eq(sticky.lastIndex,5);
const all=/a/g;all.lastIndex=1;eq([...('aaa'.matchAll(all))].map(x=>x.index).join(','),'1,2');eq(all.lastIndex,1);
eq([...('😀x'.matchAll(/(?:)/gu))].length,3);error(()=>'a'.matchAll(/a/),'TypeError');
eq('abc'.match({[Symbol.match](s){return s+'!';}}),'abc!');eq('abc'.replace({[Symbol.replace](s,r){return r+s;}},'!'),'!abc');
const custom=/x/;custom.exec=()=>({0:'custom',length:1});eq(custom.test('a'),true);custom.exec=()=>1;error(()=>custom.test('a'),'TypeError');
eq(/(a)\1/d.exec('aa').indices[1].join(','),'0,1');eq(/(?<=(a))b/d.exec('ab').indices[1].join(','),'0,1');eq(/(a)+/d.exec('aaa').indices[1].join(','),'2,3');
eq(/(a|bc)/d.exec('xbc').indices[1].join(','),'1,3');eq(/(a|bc)/d.exec('xa').indices[1].join(','),'1,2');
eq(RegExp.escape('foo-bar [x]'),'\\x66oo\\x2dbar\\x20\\[x\\]');
eq(new RegExp(RegExp.escape('a+b/😀\n'),'u').test('a+b/😀\n'),true);
eq(RegExp.escape('\ud800'),'\\ud800');error(()=>RegExp.escape(123),'TypeError');
const compiled=/a/g;compiled.lastIndex=3;eq(compiled.compile('(b)','dy'),compiled);eq(compiled.flags,'dy');eq(compiled.lastIndex,0);eq(compiled.exec('b').indices[1].join(','),'0,1');
error(()=>compiled.compile(/b/,'g'),'TypeError');
eq(compiled instanceof RegExp,true);eq(Object.prototype.toString.call(compiled),'[object RegExp]');
console.log('regexp: '+checks+' checks');$DONE();
