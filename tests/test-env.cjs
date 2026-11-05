'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const isProject = root => fs.existsSync(path.join(root, 'entry/src/main/ets/common/Models.ets'));
const candidates = process.env.NAS_PLAYER_ROOT ? [path.resolve(process.env.NAS_PLAYER_ROOT)] : [
  path.resolve(__dirname, '..'), process.cwd(), path.resolve(__dirname, '../outputs/NasPlayerHarmony')
];
const projectRoot = candidates.find(isProject);
if (!projectRoot) throw new Error('Cannot locate NasPlayerHarmony; run from its project/tests directory or set NAS_PLAYER_ROOT.');
const projectRequire = createRequire(path.join(projectRoot, 'package.json'));
let ts;
try {
  ts = process.env.TYPESCRIPT_PATH ? require(path.resolve(process.env.TYPESCRIPT_PATH)) : projectRequire('typescript');
} catch (error) {
  throw new Error('TypeScript is required: install the typescript npm package or set TYPESCRIPT_PATH to its directory/lib/typescript.js.');
}
const projectFile = relative => path.join(projectRoot, relative);
function mpvTypesFile() {
  const choices = process.env.MPV_LIB_TYPES ? [path.resolve(process.env.MPV_LIB_TYPES)] : [
    projectFile('entry/oh_modules/@mpv-ohos/mpv-arkts/src/main/ets/MpvLib.d.ets'),
    projectFile('entry/oh_modules/@mpv-ohos/mpv-arkts/src/main/ets/MpvLib.ets'),
    projectFile('oh_modules/@mpv-ohos/mpv-arkts/src/main/ets/MpvLib.d.ets'),
    projectFile('oh_modules/@mpv-ohos/mpv-arkts/src/main/ets/MpvLib.ets')
  ];
  const file = choices.find(candidate => fs.existsSync(candidate));
  if (!file) throw new Error('Installed mpv ArkTS declarations were not found; run ohpm install or set MPV_LIB_TYPES to MpvLib.d.ets.');
  return file;
}
module.exports = { projectRoot, projectFile, mpvTypesFile, ts };
