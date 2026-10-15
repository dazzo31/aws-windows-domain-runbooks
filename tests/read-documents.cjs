const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const YAML = require('yaml');
const root = path.join(__dirname, '..', 'documents');
for (const name of ['README.md', 'runbooks/DEPLOYMENT.md', 'runbooks/AD-OPERATIONS.md', 'runbooks/DNS-GPO.md', 'runbooks/WSUS.md', 'runbooks/PKI.md', 'runbooks/LAB-ACCEPTANCE.md', 'runbooks/ENVIRONMENT-ADOPTION.md', 'runbooks/NETWORK.md', 'runbooks/SECRETS.md', 'runbooks/RECOVERY.md', 'runbooks/WSUS-INTEGRATION.md', 'runbooks/REBOOT-AND-PATCH-RECOVERY.md', 'runbooks/AUDIT-AND-RETENTION.md', 'runbooks/OPERATIONS.md', 'runbooks/RELEASE.md', 'runbooks/HANDOVER.md']) {
  assert.ok(fs.existsSync(path.join(__dirname, '..', name)), `Missing runbook: ${name}`);
}
const documents = fs.readdirSync(root).filter(name => name.endsWith('.yaml')).map(name => {
  const source = fs.readFileSync(path.join(root, name), 'utf8');
  const parsed = YAML.parseDocument(source, { uniqueKeys: true });
  assert.equal(parsed.errors.length, 0, `${name}: ${parsed.errors}`);
  const document = parsed.toJS();
  assert.ok(['2.2', '0.3'].includes(document.schemaVersion), name);
  assert.ok(document.mainSteps.length > 0, name);
  assert.ok(Buffer.byteLength(source) < 65536, `${name}: exceeds SSM document size limit`);
  const scripts = [];
  for (const step of document.mainSteps) {
    if (document.schemaVersion !== '2.2') continue;
    assert.equal(step.action, 'aws:runPowerShellScript', name);
    assert.deepEqual(step.precondition.StringEquals, ['platformType', 'Windows'], name);
    for (const script of step.inputs.runCommand) {
      assert.ok(!script.includes('{{'), `${name}: unsafe raw parameter interpolation`);
      assert.ok(!/Invoke-Expression|\biex\b/i.test(script), `${name}: dynamic evaluation`);
      for (const match of script.matchAll(/\$env:SSM_([A-Za-z0-9]+)/g)) {
        assert.ok(document.parameters[match[1]], `${name}: undefined ${match[1]}`);
      }
      scripts.push(script);
    }
  }
  for (const [key, parameter] of Object.entries(document.parameters || {})) {
    if (document.schemaVersion === '2.2') {
      assert.equal(parameter.type, 'String', `${name}: ${key}`);
      assert.equal(parameter.interpolationType, 'ENV_VAR', `${name}: ${key}`);
    }
    if ('default' in parameter && parameter.allowedValues) {
      assert.ok(parameter.allowedValues.includes(parameter.default), `${name}: ${key} default`);
    }
    if ('default' in parameter && parameter.allowedPattern) {
      assert.ok(new RegExp(parameter.allowedPattern).test(parameter.default), `${name}: ${key} pattern`);
    }
  }
  if (document.parameters?.Apply) {
    assert.equal(document.parameters.Apply.default, 'false', `${name}: changes enabled by default`);
    assert.ok(scripts.some(script => script.includes('$env:SSM_Apply') && script.includes('PREVIEW')), name);
    assert.ok(document.parameters.ChangeTicket, `${name}: missing audit reference`);
  }
  if (document.schemaVersion === '0.3') {
    assert.equal(document.mainSteps[0].action, 'aws:approve', name);
    assert.equal(document.mainSteps[0].onFailure, 'Abort', name);
    assert.equal(document.mainSteps[1].action, 'aws:runCommand', name);
    assert.equal(document.mainSteps[1].maxAttempts, 1, name);
  }
  return { name, scripts };
});
assert.equal(documents.length, 19, 'The catalog must contain 19 documents (11 domain pack + 8 WUU integration documents)');
const enrollment = documents.find(document => document.name === 'WinDomain-CertificateEnrollment.yaml');
assert.ok(enrollment.scripts[0].includes('certreq.exe -enroll -machine -q -cert $env:SSM_Thumbprint Renew'), 'Renewal must identify the certificate with -cert');

// Inventory & Drift Protection: verify that all documents, runbooks, and CFN templates are indexed in README.md
const readme = fs.readFileSync(path.join(__dirname, '..', 'README.md'), 'utf8');
for (const doc of documents) {
  assert.ok(readme.includes(`documents/${doc.name}`), `README.md missing link to SSM document: documents/${doc.name}`);
}
const runbookDir = path.join(__dirname, '..', 'runbooks');
for (const rb of fs.readdirSync(runbookDir).filter(f => f.endsWith('.md'))) {
  assert.ok(readme.includes(`runbooks/${rb}`), `README.md missing link to runbook: runbooks/${rb}`);
}
const infraDir = path.join(__dirname, '..', 'infra');
for (const tmpl of fs.readdirSync(infraDir).filter(f => f.endsWith('.yaml'))) {
  assert.ok(readme.includes(`infra/${tmpl}`), `README.md missing link to infrastructure template: infra/${tmpl}`);
}

process.stdout.write(JSON.stringify(documents));