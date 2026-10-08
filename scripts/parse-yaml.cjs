const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');

const filePath = process.argv[2];
if (!filePath) {
    console.error('Usage: node parse-yaml.cjs <path-to-yaml>');
    process.exit(1);
}

const cfnTagNames = [
    '!Ref', '!Sub', '!Equals', '!Select', '!GetAtt',
    '!Condition', '!FindInMap', '!Join', '!Not', '!And', '!Or'
];
const cfnTags = cfnTagNames.map(tag => ({
    tag,
    resolve: (value) => (typeof value === 'object' && value !== null ? value.toJSON ? value.toJSON() : value : value)
}));

try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const doc = YAML.parse(raw, { customTags: cfnTags });
    process.stdout.write(JSON.stringify(doc));
} catch (e) {
    console.error(e.message);
    process.exit(1);
}

