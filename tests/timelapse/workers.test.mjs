import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, copyFile, mkdir } from 'node:fs/promises';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { deflateSync } from 'node:zlib';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const exec = promisify(execFile);
const posixShell = process.env.TIMELAPSE_POSIX_SHELL;
const windows = process.platform === 'win32' && !posixShell;
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const worker = path.join(repo, 'extensions/timelapse-recorder/workers', windows ? 'encode.ps1' : 'encode.sh');
const encoder = process.env.FFMPEG || 'ffmpeg';
const probe = process.env.FFPROBE || 'ffprobe';
let available = true;
try { await exec(encoder, ['-version']); await exec(probe, ['-version']); } catch { available = false; }
if (!available && process.env.CI) throw new Error('FFmpeg and ffprobe are required in CI');

// 生成小尺寸不透明 RGB PNG 测试图，在 MP4 解码后核对预期颜色。
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const value of buffer) {
    crc ^= value;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(name, data) {
  const bytes = Buffer.from(name), length = Buffer.alloc(4), crc = Buffer.alloc(4);
  length.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(Buffer.concat([bytes, data])));
  return Buffer.concat([length, bytes, data, crc]);
}
function png(width, height, color) {
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 2;
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    Buffer.from(color).copy(rows, y * (width * 3 + 1) + 1 + x * 3);
  }
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header),
    chunk('IDAT', deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]);
}
async function makeJob(t, settings = {}) {
  const parent = await mkdtemp(path.join(os.tmpdir(), 'timelapse-'));
  t.after(() => {
    const relative = path.relative(os.tmpdir(), parent);
    assert(!relative.startsWith('..') && !path.isAbsolute(relative));
    return rm(parent, { recursive: true, force: true });
  });
  const root = path.join(parent, "中文 % & ' $(literal) ; job");
  await mkdir(root);
  for (const [key, value] of Object.entries({ffmpeg: encoder, mode: 'encode', fps: 10, scale: 3,
    hold: 0.5, background: 'ffffff', ...settings})) {
    const setting = posixShell && key === 'ffmpeg' ? String(value).replaceAll('\\', '/') : value;
    await writeFile(path.join(root, `${key}.txt`), `${setting}\n`);
  }
  await writeFile(path.join(root, 'frame-00000001.png'), png(9, 7, [255, 0, 0]));
  await writeFile(path.join(root, 'frame-00000002.png'), png(9, 7, [0, 0, 255]));
  return root;
}
function start(root) {
  const args = windows ? ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', worker, '-JobDir', root]
    : [worker.replaceAll('\\', '/'), root.replaceAll('\\', '/')];
  const child = spawn(windows ? 'powershell.exe' : posixShell || '/bin/sh', args, {windowsHide: true, stdio: ['ignore', 'pipe', 'pipe']});
  let output = '';
  child.stdout.on('data', data => { output += data; }); child.stderr.on('data', data => { output += data; });
  const done = new Promise((resolve, reject) => {
    child.on('error', reject); child.on('close', code => resolve({code, output}));
  });
  return {child, done};
}
async function status(root) { try { return (await readFile(path.join(root, 'status'), 'utf8')).trim(); } catch { return ''; } }
async function waitStatus(root, expected, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const current = await status(root);
    if (current === expected) return;
    if (current === 'failed') throw new Error(`worker failed: ${await logs(root)}`);
    await delay(25);
  }
  throw new Error(`timed out waiting for ${expected}, got ${await status(root)}: ${await logs(root)}`);
}
async function logs(root) {
  let result = '';
  for (const name of ['worker-error.log','encode-error.log','stderr.log','probe.log','probe-error.log']) {
    try { result += await readFile(path.join(root, name), 'utf8'); } catch { /* 日志文件可能不存在。 */ }
  }
  return result;
}
test('worker encodes ordered frames, scales, pads odd dimensions and holds final frame', {skip: !available, timeout: 30000}, async t => {
  const root = await makeJob(t);
  const task = start(root); t.after(() => task.child.kill());
  const result = await task.done;
  assert.equal(await status(root), 'done', result.output + await logs(root));
  const output = path.join(root, 'encoded.mp4');
  const {stdout} = await exec(probe, ['-v','error','-select_streams','v:0','-show_entries','stream=width,height,nb_frames,duration,pix_fmt','-of','json', output]);
  const stream = JSON.parse(stdout).streams[0];
  assert.equal(stream.width, 28); assert.equal(stream.height, 22); assert.equal(stream.pix_fmt, 'yuv420p');
  assert.equal(Number(stream.nb_frames), 7); assert(Math.abs(Number(stream.duration) - 0.7) < 0.03);
  const decoded = await exec(encoder, ['-v','error','-i',output,'-f','rawvideo','-pix_fmt','rgb24','pipe:1'], {encoding: 'buffer'});
  const bytes = 28 * 22 * 3;
  const pixel = index => decoded.stdout.subarray(index * bytes + (10 * 28 + 10) * 3, index * bytes + (10 * 28 + 10) * 3 + 3);
  assert(pixel(0)[0] > 220 && pixel(0)[2] < 30);
  assert(pixel(1)[2] > 220 && pixel(1)[0] < 30);
  assert.deepEqual(pixel(1), pixel(6));
  assert((await readFile(path.join(root, 'progress.txt'), 'utf8')).includes('progress=end'));
});
test('worker checks executable and rejects missing libx264', {skip: !available, timeout: 30000}, async t => {
  const root = await makeJob(t, {ffmpeg: path.join(os.tmpdir(), 'no-such-ffmpeg-executable')});
  const task = start(root); await task.done;
  assert.equal(await status(root), 'failed');
  // ffprobe 支持 -version，但不支持 FFmpeg 的编码器列表查询。
  await writeFile(path.join(root, 'ffmpeg.txt'), `${probe}\n`);
  await start(root).done; assert.equal(await status(root), 'failed');
});
test('worker cancellation stops encoding without publishing a final output', {skip: !available, timeout: 30000}, async t => {
  const root = await makeJob(t, {scale: 16, hold: 60, fps: 120});
  for (let i = 3; i <= 300; i++) await copyFile(path.join(root, 'frame-00000001.png'), path.join(root, `frame-${String(i).padStart(8, '0')}.png`));
  const task = start(root); t.after(() => task.child.kill());
  await waitStatus(root, 'encoding');
  await writeFile(path.join(root, 'cancel'), 'cancel');
  await task.done;
  assert.equal(await status(root), 'cancelled', await logs(root));
  assert.equal((await readFile(path.join(root, 'frame-00000001.png'))).subarray(1,4).toString(), 'PNG');
});
