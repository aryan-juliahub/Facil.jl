// Writes the fixed payloads into <dir>: json_100k.json (compression rows; same generator and seed as
// the validation runs), json4k.txt and json4k.deflate (WebSocket permessage-deflate row).
const fs = require('fs'), path = require('path'), zlib = require('zlib');
const dir = process.argv[2];
fs.mkdirSync(dir, { recursive: true });
const words = ['alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel', 'india', 'juliet', 'kilo', 'lima', 'mike', 'november', 'oscar', 'papa'];
function json(target) {
  let s = 1234567; const rnd = () => (s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const rows = []; let size = 2;
  while (true) {
    const r = JSON.stringify({ id: rows.length, name: words[(rnd() * 16) | 0] + ' ' + words[(rnd() * 16) | 0], email: `user${(rnd() * 1e6) | 0}@example.com`, score: +(rnd() * 100).toFixed(3), active: rnd() > 0.5, tags: [words[(rnd() * 16) | 0], words[(rnd() * 16) | 0]], created: new Date(1.7e12 + rnd() * 1e10).toISOString() });
    if (size + r.length + 1 > target) break;
    rows.push(r); size += r.length + 1;
  }
  const body = '[' + rows.join(',') + ']';
  return body.slice(0, -1) + ' '.repeat(target - body.length) + ']';
}
fs.writeFileSync(path.join(dir, 'json_100k.json'), json(102400));
const items = []; let j;
for (let i = 0; ; i++) {
  items.push({ id: 1000 + i, name: `user-${i}`, email: `user${i}@example.com`, active: i % 2 === 0, score: +(i * 3.57).toFixed(2), tags: ['alpha', 'beta', 'gamma'].slice(0, 1 + i % 3), created_at: `2024-0${1 + i % 9}-1${i % 9}T12:${10 + i % 50}:00Z` });
  j = JSON.stringify({ items, pad: '' });
  if (j.length >= 4096 - 40) break;
}
j = JSON.stringify({ items, pad: 'x'.repeat(4096 - j.length) });
const z = zlib.deflateRawSync(j, { finishFlush: zlib.constants.Z_SYNC_FLUSH });
fs.writeFileSync(path.join(dir, 'json4k.txt'), j);
fs.writeFileSync(path.join(dir, 'json4k.deflate'), z.subarray(0, z.length - 4));
