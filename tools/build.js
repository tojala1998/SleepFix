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
// Package from an isolated staging directory, keeping editable UI sources separate.
// webOS TV uses a file:// app origin; CSP 'self' on linked local resources can be
// unreliable there. Embed both app-owned assets in index.html at build time.
const staging = path.join(out, '.app-staging');
fs.rmSync(staging, {recursive: true, force: true});
fs.cpSync(app, staging, {recursive: true});
fs.copyFileSync(path.join(root, 'LICENSE'), path.join(staging, 'LICENSE'));
for (const filename of ['sleepfixctl.sh', 'boot-hook.sh']) {
  fs.chmodSync(path.join(staging, 'bin', filename), 0o755);
}
const css = fs.readFileSync(path.join(staging, 'style.css'), 'utf8');
const js = fs.readFileSync(path.join(staging, 'app.js'), 'utf8');
if (/<\/style/i.test(css) || /<\/script/i.test(js)) {
  throw new Error('Inline assets include an unsafe HTML closing tag.');
}
let page = fs.readFileSync(path.join(staging, 'index.html'), 'utf8');
if (!page.includes('<link rel="stylesheet" href="style.css">') || !page.includes('<script src="app.js"></script>')) {
  throw new Error('Web UI asset references changed; cannot safely generate embedded package.');
}
page = page.replace('<link rel="stylesheet" href="style.css">', '<style>\n' + css + '\n</style>');
page = page.replace('<script src="app.js"></script>', '<script>\n' + js + '\n</script>');
page = page.replace('<title>SleepFix</title>',
  '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; script-src \'unsafe-inline\'; img-src data:; connect-src \'none\'; object-src \'none\'; base-uri \'none\'">\n  <title>SleepFix</title>');
fs.writeFileSync(path.join(staging, 'index.html'), page);
fs.rmSync(path.join(staging, 'app.js'));
fs.rmSync(path.join(staging, 'style.css'));
const cli = require.resolve('@webos-tools/cli/bin/ares-package.js');
try {
  cp.execFileSync(process.execPath, [cli, '--no-minify', '--outdir', out, staging], {cwd: root, stdio: 'inherit'});
} finally {
  fs.rmSync(staging, {recursive: true, force: true});
}
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
