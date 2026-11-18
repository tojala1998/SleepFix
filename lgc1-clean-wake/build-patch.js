'use strict';
// LG C1 Clean Wake v1.2.
// Build a minimal, reversible patch from the TV owner's installed StartUpUI.qml.
// No LG source code is distributed, and no firmware partition is overwritten.
const fs = require('fs');

const [originalPath, outputPath] = process.argv.slice(2);
if (!originalPath || !outputPath) {
  console.error('Usage: node build-patch.js ORIGINAL_QML OUTPUT_QML');
  process.exit(2);
}

const original = fs.readFileSync(originalPath, 'utf8');
const marker = '// LGC1_CLEAN_WAKE_V1_2';
if (original.includes(marker) || original.includes('LGC1_BRANDED_WAKE_SPLASH_')) {
  throw Error('Input appears already patched; refusing to double patch');
}

const requirements = [
  /import\s+QtQuick\s+2\.12/,
  /\bid:\s*root\b/,
  /\bproperty\s+var\s+interfaceLayer\b/,
  /\bcolor:\s*["']black["']/,
  /\bid:\s*title\b/,
  /\bid:\s*logoText\b/,
  /\bstartFadeAnimation\s*\(/,
  /\bColumn\s*\{/,
];
for (const req of requirements) {
  if (!req.test(original)) throw Error('Unexpected StartUpUI.qml structure: ' + req);
}
if ((original.match(/^[ \t]*Column\s*\{/gm) || []).length !== 1) {
  throw Error('Expected exactly one startup Column');
}

const targetAppId = `
    ${marker}
    // Hide existing startup labels for the four direct-wake streaming apps.
    // CoverUI's background, app lifecycle, wake behavior and fade are unchanged.
    property bool cleanWakeActive: {
        var target = systemProperties.appToLaunch;
        var appId = target && target.id ? target.id : "";
        return appId === "youtube.leanback.v4" ||
               appId === "netflix" ||
               appId === "amazon" ||
               appId === "com.disney.disneyplus-prod";
    }
`;

let output = original;
let anchorCount = 0;
output = output.replace(/(^[ \t]*property\s+var\s+interfaceLayer[^\r\n]*)(\r?\n)/gm,
  (whole, line, ending) => {
    anchorCount++;
    return line + ending + targetAppId;
  });
if (anchorCount !== 1) throw Error('interfaceLayer anchor must occur exactly once');

let columnCount = 0;
output = output.replace(/^([ \t]*)Column[ \t]*\{[ \t]*\r?\n/gm,
  (whole, indent) => {
    columnCount++;
    // This is visibility gating, NOT a new black overlay. Hidden children
    // are not painted and the existing root rectangle remains black.
    return whole + indent + '    visible: !root.cleanWakeActive\n';
  });
if (columnCount !== 1) throw Error('Column anchor must occur exactly once');

if ((output.match(/LGC1_CLEAN_WAKE_V1_2/g) || []).length !== 1 ||
    !output.includes('visible: !root.cleanWakeActive')) {
  throw Error('Output validation failed');
}

fs.writeFileSync(outputPath + '.tmp', output, 'utf8');
fs.renameSync(outputPath + '.tmp', outputPath);
console.log('Clean-wake QML built (' + Buffer.byteLength(output, 'utf8') + ' bytes, no Image or diagnostic components added)');
