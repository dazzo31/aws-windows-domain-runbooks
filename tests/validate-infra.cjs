/**
 * @fileoverview Offline CloudFormation template and infrastructure syntax/schema validator.
 * @module tests/validate-infra
 */

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const YAML = require('yaml');

const infraDir = path.join(__dirname, '..', 'infra');
const expectedTemplates = [
    'iam.yaml',
    'network.yaml',
    'observability.yaml',
    'orchestration.yaml',
    'secrets.yaml',
    'state.yaml',
    'storage.yaml'
];

const cfnTagNames = [
    '!Ref', '!Sub', '!Equals', '!Select', '!GetAtt',
    '!Condition', '!FindInMap', '!Join', '!Not', '!And', '!Or'
];
const cfnTags = cfnTagNames.map(tag => ({
    tag,
    resolve: (value) => (typeof value === 'object' && value !== null ? value.toJSON ? value.toJSON() : value : value)
}));

for (const tmpl of expectedTemplates) {
    const tmplPath = path.join(infraDir, tmpl);
    assert.ok(fs.existsSync(tmplPath), `Missing infrastructure template: ${tmpl}`);

    const raw = fs.readFileSync(tmplPath, 'utf8');
    const parsed = YAML.parseDocument(raw, { customTags: cfnTags, uniqueKeys: true });
    assert.equal(parsed.errors.length, 0, `${tmpl}: YAML parse errors: ${parsed.errors.join('; ')}`);

    const doc = parsed.toJS();
    assert.equal(doc.AWSTemplateFormatVersion, '2010-09-09', `${tmpl}: Missing or invalid AWSTemplateFormatVersion`);
    assert.ok(doc.Resources && Object.keys(doc.Resources).length > 0, `${tmpl}: Resources section must be non-empty`);

    if (doc.Parameters) {
        for (const [pName, pDef] of Object.entries(doc.Parameters)) {
            assert.ok(pDef.Type, `${tmpl}: Parameter ${pName} missing Type`);
            assert.ok(pDef.Description, `${tmpl}: Parameter ${pName} missing Description`);
        }
    }
}

console.log(`PASS: All ${expectedTemplates.length} CloudFormation templates parsed and validated.`);
