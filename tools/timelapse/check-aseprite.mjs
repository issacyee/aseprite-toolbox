// 等待 Windows GUI 子系统的可执行进程真正退出，并检查结果文件。
// Aseprite 即使遇到 Lua 脚本错误，也可能返回退出码 0。
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const executable = process.argv[2];
if (!executable) throw new Error('Usage: node tools/timelapse/check-aseprite.mjs <aseprite> [ffmpeg]');
await mkdir(path.join(repo, '.work'), {recursive: true});
const output = await mkdtemp(path.join(repo, '.work/timelapse-check-'));
const profile = path.join(output, 'profile');
await mkdir(profile);
const exec = promisify(execFile);
const options = {cwd: repo, windowsHide: true, encoding: 'utf8', timeout: 120000,
  env: {...process.env, ASEPRITE_USER_FOLDER: profile}};
const unit = await exec(executable, ['-b', '--script', path.join(repo, 'tests/timelapse/run.lua')], options);
if (!unit.stdout.includes('timelapse tests passed') || unit.stdout.includes('FAIL ')) throw new Error(unit.stdout + unit.stderr);
console.log(unit.stdout.trim());
const args = ['-b', '--script-param', `output=${output}`];
if (process.argv[3]) args.push('--script-param', `ffmpeg=${process.argv[3]}`);
args.push('--script', path.join(repo, 'tests/timelapse/aseprite.lua'));
const integration = await exec(executable, args, options);
const result = JSON.parse(await readFile(path.join(output, 'result.json'), 'utf8'));
if (!result.ok || result.skipped) throw new Error(JSON.stringify(result) + integration.stdout + integration.stderr);
console.log(`PASS real Aseprite integration (${result.frames} frames): ${output}`);
