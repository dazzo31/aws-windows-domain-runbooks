/**
 * @file report.mjs
 * @description Generates authoritative end-to-end WUU deployment audit reports.
 * Correlates AWS requester/approver/session IDs, Step Functions execution handles,
 * SSM command IDs, WUU operation IDs, and per-node update evidence.
 * Does not infer fleet compliance from batch counts alone.
 */

const INSTANCE_REGEX = /^i-[0-9a-f]{8,17}$/;

/**
 * Builds a structured, immutable deployment audit report.
 */
export function buildDeploymentReport({
  planId,
  planDigest,
  changeTicket,
  environment = 'lab',
  executionArn,
  requesterIdentity = 'role/wuu-operator-lab',
  approverIdentity = 'role/wuu-approver-lab',
  approvedUpdates = [],
  expectedTargetNodes = [],
  nodeResults = [],
  generatedAt = new Date().toISOString(),
}) {
  if (!planId) throw new Error('Missing required planId');
  if (!changeTicket) throw new Error('Missing required changeTicket');
  if (!Array.isArray(expectedTargetNodes) || expectedTargetNodes.length === 0) {
    throw new Error('Missing or empty required expectedTargetNodes array for strict fleet compliance determination');
  }

  const expectedTargetCount = expectedTargetNodes.length;
  const expectedInstanceIds = new Set();
  for (const expected of expectedTargetNodes) {
    if (!expected.instanceId || !INSTANCE_REGEX.test(expected.instanceId)) {
      throw new Error(`Invalid instanceId format '${expected.instanceId}' in expectedTargetNodes`);
    }
    if (expectedInstanceIds.has(expected.instanceId)) {
      throw new Error(`Duplicate instanceId '${expected.instanceId}' in expectedTargetNodes`);
    }
    expectedInstanceIds.add(expected.instanceId);
  }

  const seenReportedIds = new Set();
  
  let compliantNodes = 0;
  let failedNodes = 0;
  let quarantinedNodes = 0;
  let rebootedNodes = 0;
  let missingNodes = 0;
  let unexpectedNodes = 0;
  let duplicateNodes = 0;

  // Track duplicates and unexpected nodes in reported results
  for (const node of nodeResults) {
    if (seenReportedIds.has(node.instanceId)) {
      duplicateNodes++;
    } else {
      seenReportedIds.add(node.instanceId);
    }
    if (!expectedInstanceIds.has(node.instanceId)) {
      unexpectedNodes++;
    }
  }

  // Track any expected target nodes that produced no result
  for (const expected of expectedTargetNodes) {
    if (!seenReportedIds.has(expected.instanceId)) {
      missingNodes++;
    }
  }

  const nodeAuditRecords = nodeResults.map(node => {
    const isReboot = Boolean(node.rebootRequired || node.nativeExitCode === 3010);
    const postcheckOk = node.postcheckVerified === true;
    
    // Strict compliance: SUCCEEDED status, exit 0 (or 3010 if reboot), not quarantined,
    // and if rebooting, postcheck must be affirmatively verified true.
    const isCompliant = node.status === 'SUCCEEDED' &&
      !node.quarantined &&
      (node.nativeExitCode === 0 || (isReboot && node.nativeExitCode === 3010)) &&
      (!isReboot || postcheckOk);

    if (isCompliant) compliantNodes++;
    else failedNodes++;

    if (node.quarantined) quarantinedNodes++;
    if (isReboot) rebootedNodes++;

    return {
      instanceId: node.instanceId,
      computerName: node.computerName || node.instanceId,
      phase: node.phase || 1,
      operationId: node.operationId || `op-${planId}-${node.instanceId}`,
      commandId: node.commandId || 'cmd-unrecorded',
      status: node.status,
      nativeExitCode: node.nativeExitCode !== undefined ? node.nativeExitCode : 0,
      rebootRequired: isReboot,
      quarantined: Boolean(node.quarantined),
      updatesProcessed: node.updates || [],
      postcheckVerified: postcheckOk,
    };
  });

  const totalNodes = expectedTargetCount;

  // Strict fleet compliance rule: Fleet is compliant ONLY if:
  // - Exactly totalNodes succeeded and were compliant
  // - Zero missing nodes, zero unexpected nodes, zero duplicate nodes, zero quarantined, zero failed
  const fleetCompliant = totalNodes > 0 &&
    compliantNodes === totalNodes &&
    quarantinedNodes === 0 &&
    missingNodes === 0 &&
    unexpectedNodes === 0 &&
    duplicateNodes === 0 &&
    failedNodes === 0;

  return {
    schemaVersion: '1.0.0',
    reportId: `rpt-${planId}`,
    generatedAt,
    environment,
    changeTicket,
    governance: {
      planId,
      planDigest: planDigest || 'unverified',
      executionArn: executionArn || 'untracked',
      requesterIdentity,
      approverIdentity,
      approvalPolicy: 'FixedEnvironmentApproverRole',
    },
    summary: {
      totalNodes,
      compliantNodes,
      failedNodes,
      quarantinedNodes,
      rebootedNodes,
      fleetCompliant,
      complianceDetermination: fleetCompliant
        ? 'ALL_NODES_VERIFIED_COMPLIANT'
        : 'FLEET_NON_COMPLIANT_OR_PARTIAL',
    },
    approvedUpdatesScope: approvedUpdates,
    nodeAudits: nodeAuditRecords,
  };
}

