import test from 'node:test';
import assert from 'node:assert/strict';
import { inflateRawSync } from 'node:zlib';
import { buildPackage } from '../../tools/timelapse/package.mjs';

test('package is deterministic and contains the complete standalone extension', async () => {
  const result = await buildPackage();
  assert.deepEqual(result.buffer, (await buildPackage()).buffer);
  const files = new Map();
  let offset = 0;
  while (result.buffer.readUInt32LE(offset) === 0x04034b50) {
    const length = result.buffer.readUInt32LE(offset + 18);
    const size = result.buffer.readUInt32LE(offset + 22);
    const nameLength = result.buffer.readUInt16LE(offset + 26);
    const extraLength = result.buffer.readUInt16LE(offset + 28);
    const name = result.buffer.subarray(offset + 30, offset + 30 + nameLength).toString();
    const start = offset + 30 + nameLength + extraLength;
    const data = inflateRawSync(result.buffer.subarray(start, start + length));
    assert.equal(data.length, size);
    assert(!name.includes('..') && !name.startsWith('/') && !name.includes('tests/'));
    files.set(name, data.toString());
    // 只检查公开的产品描述字段；Lua 中文注释和中文 README 不受此检查限制。
    if (name === 'package.json') {
      const metadata = JSON.parse(data.toString());
      for (const field of ['displayName', 'description']) {
        assert(!/\p{Script=Han}/u.test(metadata[field]), 'Public extension metadata must use English: ' + field);
      }
    }
    offset = start + length;
  }
  assert.equal(result.buffer.readUInt32LE(offset), 0x02014b50);
  assert.equal(result.buffer.readUInt32LE(result.buffer.length - 22), 0x06054b50);
  assert.equal(result.buffer.readUInt16LE(result.buffer.length - 12), files.size);
  const manifest = JSON.parse(files.get('package.json'));
  for (const script of manifest.contributes.scripts) assert(files.has(script.path.replace(/^\.\//, '')));
  for (const name of ['lib/fs.lua', 'lib/store.lua', 'lib/recorder.lua', 'lib/platform.lua', 'lib/export.lua',
    'workers/encode.sh', 'workers/encode.ps1', 'README.md', 'LICENSE']) assert(files.has(name), name);
});
