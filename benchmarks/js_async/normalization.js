for (const value of ['e\u0301', '\u212b', '\ufb01', '\u1100\u1161\u11a8', '\ud800A\udc00']) {
  console.log(['NFC', 'NFD', 'NFKC', 'NFKD'].map(form => JSON.stringify(value.normalize(form))).join(' '));
}
try { ''.normalize('nfc'); } catch (error) { console.log(error.name); }
console.log(String.prototype.normalize.call(12));
$DONE();
