/* SPDX-License-Identifier: MIT */
'use strict';
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const crypto = require('crypto');
const root = path.resolve(__dirname, '..');
const app = path.join(root, 'app');
const out = path.join(root, 'dist');
const info = JSON.parse(fs.readFileSync(path.join(app, 'appinfo.json'), 'utf8'));
const repository = process.env.SLEEPFIX_REPOSITORY_URL || 'https://github.com/tojala1998/SleepFix';
if (!/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
  throw new Error('SLEEPFIX_REPOSITORY_URL must be a plain HTTPS GitHub repository URL.');
}
if (info.id !== 'io.github.tojala1998.sleepfix' || !/^\d+\.\d+\.\d+$/.test(info.version)) {
  throw new Error('Unexpected application identity/version.');
}
fs.mkdirSync(out, {recursive: true});
fs.copyFileSync(path.join(root, 'LICENSE'), path.join(app, 'LICENSE'));
for (const filename of ['sleepfixctl.sh', 'boot-hook.sh']) {
  fs.chmodSync(path.join(app, 'bin', filename), 0o755);
}
const cli = require.resolve('@webos-tools/cli/bin/ares-package.js');
cp.execFileSync(process.execPath, [cli, '--no-minify', '--outdir', out, app], {cwd: root, stdio: 'inherit'});
const ipkName = info.id + '_' + info.version + '_all.ipk';
const bytes = fs.readFileSync(path.join(out, ipkName));
const digest = crypto.createHash('sha256').update(bytes).digest('hex');
const rawBase = repository.replace('https://github.com/', 'https://raw.githubusercontent.com/');
const manifest = {
  id: info.id, version: info.version, type: 'web', title: info.title,
  appDescription: info.appDescription,
  iconUri: rawBase + '/main/app/icon160.png',
  sourceUrl: repository,
  rootRequired: true,
  ipkUrl: ipkName,
  ipkHash: {sha256: digest},
  ipkSize: bytes.length
};
fs.writeFileSync(path.join(out, info.id + '.manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
fs.writeFileSync(path.join(out, 'SHA256SUMS'), digest + '  ' + ipkName + '\n');
console.log('IPK SHA-256: ' + digest);
console.log('Generated release manifest. Its GitHub URLs become live only after publication.');
