// 此扩展专用的 ZIP 打包程序，无外部依赖，需要 Node.js 20 或更新版本。
import { readFile, readdir, mkdir, writeFile, lstat } from 'node:fs/promises';
import { deflateRawSync } from 'node:zlib';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const source = path.join(repo, 'extensions/timelapse-recorder');
const crcTable = Array.from({ length: 256 }, (_, index) => {
  let crc = index;
  for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  return crc >>> 0;
});
function crc32(data) {
  let crc = 0xffffffff;
  for (const byte of data) crc = (crc >>> 8) ^ crcTable[(crc ^ byte) & 255];
  return (crc ^ 0xffffffff) >>> 0;
}
export async function buildPackage() {
  const manifest = JSON.parse(await readFile(path.join(source, 'package.json'), 'utf8'));
  if (!/^\d+\.\d+\.\d+$/.test(manifest.version)) throw new Error('Invalid extension version');
  const files = ['package.json', 'main.lua', 'README.md'];
  for (const folder of ['lib', 'workers']) {
    for (const file of (await readdir(path.join(source, folder))).sort()) {
      if (!/\.(lua|sh|ps1)$/.test(file) || !(await lstat(path.join(source, folder, file))).isFile()) {
        throw new Error(`Unexpected runtime file: ${folder}/${file}`);
      }
      files.push(`${folder}/${file}`);
    }
  }
  const entries = [];
  for (const file of files) entries.push([file, await readFile(path.join(source, file))]);
  entries.push(['LICENSE', await readFile(path.join(repo, 'LICENSE'))]);
  const local = [], central = [];
  let offset = 0;
  for (const [file, data] of entries) {
    const name = Buffer.from(file), compressed = deflateRawSync(data), crc = crc32(data);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0); header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x800, 6); header.writeUInt16LE(8, 8); header.writeUInt16LE(33, 12);
    header.writeUInt32LE(crc, 14); header.writeUInt32LE(compressed.length, 18);
    header.writeUInt32LE(data.length, 22); header.writeUInt16LE(name.length, 26);
    local.push(header, name, compressed);
    const index = Buffer.alloc(46);
    index.writeUInt32LE(0x02014b50, 0); index.writeUInt16LE(20, 4); index.writeUInt16LE(20, 6);
    index.writeUInt16LE(0x800, 8); index.writeUInt16LE(8, 10); index.writeUInt16LE(33, 14);
    index.writeUInt32LE(crc, 16); index.writeUInt32LE(compressed.length, 20);
    index.writeUInt32LE(data.length, 24); index.writeUInt16LE(name.length, 28);
    index.writeUInt32LE(offset, 42); central.push(index, name);
    offset += header.length + name.length + compressed.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return { manifest, files: entries.map(([name]) => name), buffer: Buffer.concat([...local, directory, end]) };
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const result = await buildPackage();
  const target = path.join(repo, 'dist', `timelapse-recorder-${result.manifest.version}.aseprite-extension`);
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, result.buffer);
  console.log(`${target} (${result.files.length} files, ${result.buffer.length} bytes)`);
}
