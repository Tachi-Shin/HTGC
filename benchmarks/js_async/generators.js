let checks = 0;
function eq(a, b) { checks++; if (!Object.is(a,b)) throw new Error('generator check '+checks+': '+String(a)+' != '+String(b)); }
function step(g, value, done, input) { const result=g.next(input); eq(result.value,value); eq(result.done,done); }
function error(f,name) { let caught='';try {f();}catch(e){caught=e.name;}eq(caught,name); }
let events=[];
function* basic(a) { events.push('start');const b=yield a;try {yield b+1;return 9;}finally{events.push('end');} }
let g=basic(3);eq(events.length,0);eq(g[Symbol.iterator](),g);
step(g,3,false,100);step(g,6,false,5);step(g,9,true);step(g,undefined,true);
eq(events.join(','),'start,end');error(()=>new basic(),'TypeError');
function* closing(){try {yield 1;}finally{yield 2;events.push('closed');} }
g=closing();step(g,1,false);let r=g.return(7);eq(r.value,2);eq(r.done,false);step(g,7,true);
g=closing();r=g.return(8);eq(r.value,8);eq(r.done,true);step(g,undefined,true);
function* catching(){try {yield 1;}catch(e){yield e;}finally{yield 3;}return 4;}
g=catching();step(g,1,false);r=g.throw('caught');eq(r.value,'caught');eq(r.done,false);step(g,3,false);step(g,4,true);
g=catching();error(()=>g.throw(new TypeError()),'TypeError');step(g,undefined,true);
function* inner(){const input=yield 2;return input+1;}
function* outer(){yield 1;return yield* inner();}
g=outer();step(g,1,false);step(g,2,false);step(g,8,true,7);
function* iterable(){yield* [2,3];yield* '😀x';}
eq([...iterable()].join(','),'2,3,😀,x');
let closed=false;
const delegate={ [Symbol.iterator](){return this;},next(){return {value:1,done:false};},return(){closed=true;return {done:true};} };
function* missingThrow(){yield* delegate;}
g=missingThrow();g.next();error(()=>g.throw(1),'TypeError');eq(closed,true);
let recursive;
function* recursion(){error(()=>recursive.next(),'TypeError');yield 1;}
recursive=recursion();step(recursive,1,false);
function* expressions(){
  let x=yield 1; x+=yield 2;
  yield false && (yield 100);yield true || (yield 200);
  yield x>2 ? (yield 3) : (yield 300);
  const obj={['x'+(yield 4)]:yield 5};yield obj.xa;
  const array=[yield 6,...[yield 7]];yield array.join(',');
  return `v${yield 8}!`;
}
g=expressions();step(g,1,false);step(g,2,false,2);step(g,false,false,3);step(g,true,false);step(g,3,false);step(g,10,false,10);
step(g,4,false);step(g,5,false,'a');step(g,20,false,20);step(g,6,false);step(g,7,false,30);step(g,'30,40',false,40);step(g,8,false);step(g,'v50!',true,50);
function* loops(){for(let i=0;i<4;i++){if(i===1)continue;yield i;}let j=0;while((yield j)<3)j++;do{yield 9;}while(yield false);switch(yield 10){case yield 11:yield 12;break;default:yield 13;} }
g=loops();step(g,0,false);step(g,2,false);step(g,3,false);step(g,0,false);step(g,1,false,1);step(g,9,false,3);step(g,false,false);step(g,10,false,false);step(g,11,false,7);step(g,12,false,7);step(g,undefined,true);
function* cleanup(){try{yield 1;yield 2;}finally{closed=true;}}
closed=false;for(const x of cleanup()){eq(x,1);break;}eq(closed,true);
function* defaults(){const {a=yield 1,b=yield 100}={b:9};const [c=yield 2]=[];yield [a,b,c].join(',');for(const {d=yield 3} of [{}])yield d;}
g=defaults();step(g,1,false);step(g,2,false,7);step(g,'7,9,8',false,8);step(g,3,false);step(g,10,false,10);step(g,undefined,true);
async function* asyncValues(){const x=await Promise.resolve(2);yield Promise.resolve(x);try{yield 3;}finally{yield 4;}return 5;}
(async()=>{
  const a=asyncValues();eq(a[Symbol.asyncIterator](),a);
  const requests=[a.next(),a.next(),a.return(9),a.next()];
  const results=await Promise.all(requests);eq(results.map(x=>x.value).join(','),'2,3,4,9');eq(results.map(x=>x.done).join(','),'false,false,false,true');
  async function* recovered(){try{yield Promise.reject('bad');}catch(e){yield e;}return await Promise.resolve(8);}
  const b=recovered();eq((await b.next()).value,'bad');eq((await b.next()).value,8);
  async function* delegated(){return yield* asyncValues();}
  const c=delegated();eq((await c.next()).value,2);eq((await c.next()).value,3);eq((await c.next()).value,4);r=await c.next();eq(r.value,5);eq(r.done,true);
  let sum=0;for await(const x of [Promise.resolve(2),3])sum+=x;eq(sum,5);
  for await(const x of asyncValues()){eq(x,2);break;}
  async function* forwarding(){for await(const x of [Promise.resolve(1),2])yield x*2;}
  let values=[];for await(const x of forwarding())values.push(x);eq(values.join(','),'2,4');
  let finished=false;async function* finalizing(){try{yield 1;}finally{await Promise.resolve();finished=true;}}
  for await(const x of finalizing()){break;}eq(finished,true);
  let original='';try{for await(const x of { [Symbol.asyncIterator](){return this;},next(){return Promise.resolve({value:1,done:false});},return(){return Promise.reject('close');}}){throw 'body';}}catch(e){original=e;}eq(original,'body');
  async function* failedReturn(){try{return Promise.reject('return rejected');}catch(e){yield e;}finally{yield 'finally';}}
  const failed=failedReturn();eq((await failed.next()).value,'return rejected');eq((await failed.next()).value,'finally');eq((await failed.next()).done,true);
  async function* injectedReturn(){try{yield 1;}catch(e){yield e;}finally{yield 3;}}
  const injected=injectedReturn();await injected.next();eq((await injected.return(Promise.reject('injected'))).value,'injected');eq((await injected.next()).value,3);
  console.log('generators: '+checks+' checks');$DONE();
})().catch($DONE);
