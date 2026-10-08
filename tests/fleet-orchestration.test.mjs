import test from 'node:test';
import assert from 'node:assert/strict';
import { dispatchOperation } from '../cloud/dispatch.mjs';
import { reconcileOperation } from '../cloud/reconcile.mjs';
import { cancelDeployment, hasSufficientBudget } from '../cloud/cancel.mjs';
import { buildDeploymentReport } from '../cloud/report.mjs';
import { computePlanDigest } from '../cloud/build-plan.mjs';
import { releaseNodeLock } from '../cloud/state.mjs';

test('cloud/dispatch.mjs: validates action and targets', async () => {
  await assert.rejects(
    async () => {
      await dispatchOperation({
        instanceId: 'invalid-id',
        action: 'Install',
        planId: 'plan-1234',
        changeTicket: 'CHG-100',
      });
    },
    /Invalid or missing EC2 instanceId/
  );

  await assert.rejects(
    async () => {
      await dispatchOperation({
        instanceId: 'i-0123456789abcdef0',
        action: 'InvalidAction',
        planId: 'plan-1234',
        changeTicket: 'CHG-100',
      });
    },
    /Invalid action/
  );

  const res = await dispatchOperation({
    instanceId: 'i-0123456789abcdef0',
    action: 'Install',
    planId: 'plan-01234567-89ab-cdef-0123-456789abcdef',
    changeTicket: 'CHG-100',
    workerPackage: {
      s3Uri: 's3://bucket/pkg.zip',
      versionId: 'v1',
      sha256: 'a'.repeat(64),
    },
  });

  assert.equal(res.success, true);
  assert.equal(res.status, 'DISPATCHED');
  assert.equal(res.instanceId, 'i-0123456789abcdef0');
});

test('cloud/reconcile.mjs: handles in-progress and successful invocations', async () => {
  const inProgress = await reconcileOperation({
    commandId: 'cmd-1',
    instanceId: 'i-0123456789abcdef0',
    operationId: 'op-1',
    mockInvocation: {
      Status: 'InProgress',
    },
  });
  assert.equal(inProgress.completed, false);
  assert.equal(inProgress.status, 'IN_PROGRESS');

  const success = await reconcileOperation({
    commandId: 'cmd-1',
    instanceId: 'i-0123456789abcdef0',
    operationId: 'op-1',
    mockInvocation: {
      Status: 'Success',
      ResponseCode: 0,
      StandardOutputContent: '{"schemaVersion":"1.0.0","status":"SUCCESS","rebootRequired":false}',
    },
  });
  assert.equal(success.completed, true);
  assert.equal(success.status, 'SUCCEEDED');
  assert.equal(success.rebootRequired, false);

  const rebootRequired = await reconcileOperation({
    commandId: 'cmd-1',
    instanceId: 'i-0123456789abcdef0',
    operationId: 'op-1',
    mockInvocation: {
      Status: 'Success',
      ResponseCode: 3010,
    },
  });
  assert.equal(rebootRequired.completed, true);
  assert.equal(rebootRequired.rebootRequired, true);

  const transportFailure = await reconcileOperation({
    commandId: 'cmd-1',
    instanceId: 'i-0123456789abcdef0',
    operationId: 'op-1',
    mockInvocation: {
      Status: 'Undeliverable',
    },
  });
  assert.equal(transportFailure.completed, true);
  assert.equal(transportFailure.status, 'FAILED');
  assert.equal(transportFailure.quarantined, true);
});

test('cloud/cancel.mjs: checks budget and graceful cancellation', async () => {
  const future = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  assert.equal(hasSufficientBudget({ deadlineTime: future, minimumRequiredMinutes: 30 }), true);

  const past = new Date(Date.now() - 60 * 1000).toISOString();
  assert.equal(hasSufficientBudget({ deadlineTime: past, minimumRequiredMinutes: 30 }), false);

  const cancelRes = await cancelDeployment({
    planId: 'plan-1234',
    reason: 'Operator cancelled',
  });
  assert.equal(cancelRes.success, true);
  assert.equal(cancelRes.status, 'CANCELLING');
  assert.equal(cancelRes.activeInstallersPreserved, true);
});

test('cloud/report.mjs: correlates lineage and verifies strict fleet compliance', () => {
  const expectedTargetNodes = [
    { instanceId: 'i-0123456789abcdef0' },
    { instanceId: 'i-0123456789abcdef1' },
  ];

  const report = buildDeploymentReport({
    planId: 'plan-1234',
    planDigest: 'a'.repeat(64),
    changeTicket: 'CHG-100',
    expectedTargetNodes,
    nodeResults: [
      {
        instanceId: 'i-0123456789abcdef0',
        status: 'SUCCEEDED',
        nativeExitCode: 0,
        rebootRequired: false,
        quarantined: false,
      },
      {
        instanceId: 'i-0123456789abcdef1',
        status: 'SUCCEEDED',
        nativeExitCode: 0,
        rebootRequired: false,
        quarantined: false,
      },
    ],
  });

  assert.equal(report.summary.totalNodes, 2);
  assert.equal(report.summary.compliantNodes, 2);
  assert.equal(report.summary.fleetCompliant, true);
  assert.equal(report.summary.complianceDetermination, 'ALL_NODES_VERIFIED_COMPLIANT');

  const failedReport = buildDeploymentReport({
    planId: 'plan-1234',
    planDigest: 'a'.repeat(64),
    changeTicket: 'CHG-100',
    expectedTargetNodes,
    nodeResults: [
      {
        instanceId: 'i-0123456789abcdef0',
        status: 'SUCCEEDED',
        nativeExitCode: 0,
        quarantined: false,
      },
      {
        instanceId: 'i-0123456789abcdef1',
        status: 'FAILED',
        nativeExitCode: 5,
        quarantined: true,
      },
    ],
  });

  assert.equal(failedReport.summary.totalNodes, 2);
  assert.equal(failedReport.summary.compliantNodes, 1);
  assert.equal(failedReport.summary.failedNodes, 1);
  assert.equal(failedReport.summary.quarantinedNodes, 1);
  assert.equal(failedReport.summary.fleetCompliant, false);
  assert.equal(failedReport.summary.complianceDetermination, 'FLEET_NON_COMPLIANT_OR_PARTIAL');
});

test('F1 regression: canonical plan digest is deterministic and preserves nested keys', () => {
  const planA = {
    zKey: 'last',
    targetNodes: [
      { instanceId: 'i-1', phase: 1 },
      { instanceId: 'i-2', phase: 2 },
    ],
    approvedUpdates: ['KB123456'],
    workerPackage: {
      s3Uri: 's3://bucket/pkg.zip',
      sha256: 'abc123',
    },
    action: 'Install',
  };

  const planB = {
    action: 'Install',
    workerPackage: {
      sha256: 'abc123',
      s3Uri: 's3://bucket/pkg.zip',
    },
    approvedUpdates: ['KB123456'],
    targetNodes: [
      { phase: 1, instanceId: 'i-1' },
      { phase: 2, instanceId: 'i-2' },
    ],
    zKey: 'last',
  };

  const digestA = computePlanDigest(planA);
  const digestB = computePlanDigest(planB);

  assert.equal(digestA, digestB, 'Shuffled key insertion order must yield identical digest');
  assert.equal(typeof digestA, 'string');
  assert.equal(digestA.length, 64);

  // Undefined properties must throw rather than being silently dropped
  assert.throws(
    () => computePlanDigest({ ...planA, badProp: undefined }),
    /Undefined property 'badProp' encountered during plan canonicalization/
  );

  // Undefined array items must throw rather than being silently dropped
  assert.throws(
    () => computePlanDigest({ ...planA, targetNodes: [undefined] }),
    /Undefined array element at index 0 encountered during plan canonicalization/
  );
});

test('F2 regression: reconcileOperation maps terminal failures (Failed, TimedOut, Cancelled) to completed: true and status: FAILED', async () => {
  for (const terminalStatus of ['Failed', 'TimedOut', 'Cancelled']) {
    const res = await reconcileOperation({
      commandId: 'cmd-term',
      instanceId: 'i-0123456789abcdef0',
      operationId: 'op-term',
      owner: 'test-owner',
      fencingToken: 1,
      mockInvocation: {
        Status: terminalStatus,
        ResponseCode: 1,
      },
    });
    assert.equal(res.completed, true, `Terminal status ${terminalStatus} must complete poll loop`);
    assert.equal(res.status, 'FAILED', `Terminal status ${terminalStatus} must map to FAILED`);
  }
});

test('F3 regression: releaseNodeLock mandates owner and fencingToken', async () => {
  await assert.rejects(
    async () => {
      await releaseNodeLock({
        instanceId: 'i-12345',
        operationId: 'op-1',
        fencingToken: 1,
      });
    },
    /releaseNodeLock requires owner/
  );

  await assert.rejects(
    async () => {
      await releaseNodeLock({
        instanceId: 'i-12345',
        operationId: 'op-1',
        owner: 'test-owner',
      });
    },
    /releaseNodeLock requires fencingToken/
  );

  const releaseRes = await releaseNodeLock({
    instanceId: 'i-12345',
    operationId: 'op-1',
    owner: 'test-owner',
    fencingToken: 2,
  });

  assert.equal(releaseRes.success, true);
  assert.equal(releaseRes.lockStatus, 'RELEASED');
  assert.equal(releaseRes.fencingToken, 2);
});

test('F7 regression: report enforces strict denominator, bidirectional set equality, and affirmative postcheck', () => {
  const expectedNodes = [
    { instanceId: 'i-0123456789abcdef1', computerName: 'node1' },
    { instanceId: 'i-0123456789abcdef2', computerName: 'node2' },
  ];

  // 1. Missing node in report fails fleet compliance
  const missingNodeReport = buildDeploymentReport({
    planId: 'plan-1',
    changeTicket: 'CHG-1',
    expectedTargetNodes: expectedNodes,
    nodeResults: [
      { instanceId: 'i-0123456789abcdef1', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
    ],
  });
  assert.equal(missingNodeReport.summary.fleetCompliant, false);
  assert.equal(missingNodeReport.summary.totalNodes, 2);
  assert.equal(missingNodeReport.summary.compliantNodes, 1);

  // 2. Unexpected node in report fails fleet compliance
  const unexpectedNodeReport = buildDeploymentReport({
    planId: 'plan-1',
    changeTicket: 'CHG-1',
    expectedTargetNodes: expectedNodes,
    nodeResults: [
      { instanceId: 'i-0123456789abcdef1', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
      { instanceId: 'i-0123456789abcdef2', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
      { instanceId: 'i-0123456789abcdef9', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
    ],
  });
  assert.equal(unexpectedNodeReport.summary.fleetCompliant, false);

  // 3. Duplicate node in report fails fleet compliance
  const duplicateNodeReport = buildDeploymentReport({
    planId: 'plan-1',
    changeTicket: 'CHG-1',
    expectedTargetNodes: expectedNodes,
    nodeResults: [
      { instanceId: 'i-0123456789abcdef1', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
      { instanceId: 'i-0123456789abcdef1', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
    ],
  });
  assert.equal(duplicateNodeReport.summary.fleetCompliant, false);

  // 4. Rebooted node without affirmative postcheck fails fleet compliance
  const rebootNoPostcheckReport = buildDeploymentReport({
    planId: 'plan-1',
    changeTicket: 'CHG-1',
    expectedTargetNodes: expectedNodes,
    nodeResults: [
      { instanceId: 'i-0123456789abcdef1', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
      { instanceId: 'i-0123456789abcdef2', status: 'SUCCEEDED', nativeExitCode: 3010, rebootRequired: true, postcheckVerified: false },
    ],
  });
  assert.equal(rebootNoPostcheckReport.summary.fleetCompliant, false);

  // 5. Full affirmative pass succeeds
  const fullPassReport = buildDeploymentReport({
    planId: 'plan-1',
    changeTicket: 'CHG-1',
    expectedTargetNodes: expectedNodes,
    nodeResults: [
      { instanceId: 'i-0123456789abcdef1', status: 'SUCCEEDED', nativeExitCode: 0, postcheckVerified: true },
      { instanceId: 'i-0123456789abcdef2', status: 'SUCCEEDED', nativeExitCode: 3010, rebootRequired: true, postcheckVerified: true },
    ],
  });
  assert.equal(fullPassReport.summary.fleetCompliant, true);
  assert.equal(fullPassReport.summary.complianceDetermination, 'ALL_NODES_VERIFIED_COMPLIANT');

  // 6. expectedTargetNodes with missing, invalid format, or duplicate instanceId throws
  assert.throws(
    () => buildDeploymentReport({
      planId: 'plan-1',
      changeTicket: 'CHG-1',
      expectedTargetNodes: [{ computerName: 'missing-id' }],
      nodeResults: [],
    }),
    /Invalid instanceId format 'undefined' in expectedTargetNodes/
  );

  assert.throws(
    () => buildDeploymentReport({
      planId: 'plan-1',
      changeTicket: 'CHG-1',
      expectedTargetNodes: [{ instanceId: 'bad-format' }],
      nodeResults: [],
    }),
    /Invalid instanceId format 'bad-format' in expectedTargetNodes/
  );

  assert.throws(
    () => buildDeploymentReport({
      planId: 'plan-1',
      changeTicket: 'CHG-1',
      expectedTargetNodes: [
        { instanceId: 'i-0123456789abcdef0' },
        { instanceId: 'i-0123456789abcdef0' },
      ],
      nodeResults: [],
    }),
    /Duplicate instanceId 'i-0123456789abcdef0' in expectedTargetNodes/
  );
});

test('Reconcile reboot & verify commands release lock with owner and token via DynamoDB', async () => {
  const releasedLocks = [];
  const mockDynamo = {
    updateItem: async (params) => {
      releasedLocks.push(params);
      return {};
    },
    putItem: async () => ({}),
  };

  const rebootRes = await reconcileOperation({
    commandId: 'cmd-reboot-1',
    instanceId: 'i-0123456789abcdef0',
    operationId: 'op-reboot-1',
    owner: 'dispatch-worker',
    fencingToken: 4,
    dynamoClient: mockDynamo,
    mockInvocation: {
      Status: 'Success',
      ResponseCode: 3010,
    },
  });

  assert.equal(rebootRes.completed, true);
  assert.equal(rebootRes.rebootRequired, true);
  assert.equal(releasedLocks.length, 1);
  assert.match(releasedLocks[0].ConditionExpression, /#operationId = :opId AND #owner = :owner AND #fencingToken = :token/);
  assert.equal(releasedLocks[0].ExpressionAttributeValues[':owner'].S, 'dispatch-worker');
  assert.equal(releasedLocks[0].ExpressionAttributeValues[':token'].N, '4');
});
