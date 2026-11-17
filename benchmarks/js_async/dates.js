let checks=0;
function eq(a,b){checks++;if(!Object.is(a,b))throw new Error('date check '+checks+': '+String(a)+' != '+String(b));}
function error(f,name){let caught='';try{f();}catch(e){caught=e.name;}eq(caught,name);}
for(const time of [0,-1,1,1234567890123,-62167219200000,8640000000000000,-8640000000000000]){
  const d=new Date(time);eq(d.getTime(),time);eq(Date.parse(d.toISOString()),time);
  if(time>=0 && time<253402300800000){const whole=new Date(Math.floor(time/1000)*1000);eq(Date.parse(whole.toUTCString()),whole.getTime());eq(Date.parse(whole.toString()),whole.getTime());}
}
eq(new Date(-0).getTime(),0);eq(new Date(-1.9).getTime(),-1);
eq(new Date(8640000000000001).getTime(),NaN);eq(new Date(Infinity).getTime(),NaN);eq(new Date(undefined).getTime(),NaN);
eq(new Date(NaN).toJSON(),null);eq(new Date(NaN).toString(),'Invalid Date');error(()=>new Date(NaN).toISOString(),'RangeError');
eq(Date.UTC(2000,1,29),951782400000);eq(Date.UTC(99,0),915148800000);eq(Date.UTC(2000,-1),944006400000);eq(Date.UTC(),NaN);
eq(new Date('2024-02-29T12:34:56.789+09:00').toISOString(),'2024-02-29T03:34:56.789Z');
eq(new Date('2024-01-01T24:00:00.000Z').toISOString(),'2024-01-02T00:00:00.000Z');
eq(Date.parse('2024-13-01'),NaN);eq(Date.parse('2024-01-01T24:01:00Z'),NaN);
let d=new Date('2000-02-29T12:34:56.789Z');
eq(d.getUTCFullYear(),2000);eq(d.getUTCMonth(),1);eq(d.getUTCDate(),29);eq(d.getUTCDay(),2);eq(d.getUTCHours(),12);eq(d.getUTCMinutes(),34);eq(d.getUTCSeconds(),56);eq(d.getUTCMilliseconds(),789);
eq(d.setUTCFullYear(2001),983450096789);eq(d.toISOString(),'2001-03-01T12:34:56.789Z');
d.setUTCMonth(0,32);eq(d.toISOString(),'2001-02-01T12:34:56.789Z');d.setUTCHours(25,61,61,1001);eq(d.toISOString(),'2001-02-02T02:02:02.001Z');
d.setTime(NaN);d.setUTCFullYear(2020);eq(d.toISOString(),'2020-01-01T00:00:00.000Z');d.setTime(NaN);eq(d.setUTCMonth(0),NaN);
const original=new Date(100);original.valueOf=()=>200;eq(new Date(original).getTime(),100);
eq(Date.prototype.toJSON.call({valueOf(){return 1;},toISOString(){return 'custom';}}),'custom');
error(()=>Date.prototype.getTime.call({}),'TypeError');error(()=>Date.prototype[Symbol.toPrimitive].call(new Date(),'bad'),'TypeError');
const local=new Date(2024,0,2,3,4,5,6);eq(local.getFullYear(),2024);eq(local.getMonth(),0);eq(local.getDate(),2);eq(local.getHours(),3);eq(local.getMinutes(),4);eq(local.getSeconds(),5);eq(local.getMilliseconds(),6);
eq(local instanceof Date,true);eq(Object.prototype.toString.call(local),'[object Date]');
console.log('dates: '+checks+' checks');$DONE();
