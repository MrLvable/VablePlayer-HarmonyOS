'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const scripts = fs.readdirSync(path.join(root, 'tests')).filter(name => /^validate-.*\.cjs$/.test(name)).sort();
let failed = 0;
for (const name of scripts) {
  const result = spawnSync(process.execPath, [path.join(root, 'tests', name)], {
    cwd: root, env: process.env, encoding: 'utf8', timeout: 120000, maxBuffer: 16 * 1024 * 1024
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0 || result.error) { failed++; console.error('FAILED: ' + name); }
}
console.log(JSON.stringify({scripts: scripts.length, passed: scripts.length-failed, failed}));
process.exitCode = failed ? 1 : 0;
