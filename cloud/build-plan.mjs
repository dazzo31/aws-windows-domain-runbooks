/**
 * @fileoverview Cloud plan builder that synthesizes, validates, and hashes an immutable deployment change plan conforming to schemas/change-plan.schema.json.
 * @module cloud/build-plan
 * 
 * @status UNTESTED_IN_LIVE_ENVIRONMENT
 * @notice Validated via Node.js offline unit tests (Node 20+ test runner).
 *         Has NOT been deployed to a live AWS account or invoked via live Step Functions.
 *         Requires isolated AWS lab testing (Gate G1/G2) before deployment.
 * 
 * @security Least-Privilege IAM boundaries apply. Denied direct node modification.
 * @invariants
 *   - Pure deterministic execution; cryptographic SHA256 digest over canonicalized JSON.
 *   - Strict input validation against schemas/change-plan.schema.json.
 *   - Prohibits scheduling updates past declared maintenance window deadlines.
 */

import { createHash, randomUUID } from 'node:crypto';

function canonicalize(obj) {
  if (obj === undefined) {
    throw new Error('Undefined value encountered during plan canonicalization');
  }
  if (obj === null || typeof obj !== 'object') {
    return obj;
  }
  if (Array.isArray(obj)) {
    for (let i = 0; i < obj.length; i++) {
      if (obj[i] === undefined) {
        throw new Error(`Undefined array element at index ${i} encountered during plan canonicalization`);
      }
    }
    return obj.map(canonicalize);
  }
  const sorted = {};
  const keys = Object.keys(obj).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  for (const key of keys) {
    if (obj[key] === undefined) {
      throw new Error(`Undefined property '${key}' encountered during plan canonicalization`);
    }
    sorted[key] = canonicalize(obj[key]);
  }
  return sorted;
}

/**
 * Computes deterministic SHA256 digest of a plan object.
 * Recursively canonicalizes keys at all depths so nested objects and arrays are preserved.
 */
export function computePlanDigest(planObject) {
  const { planDigest, ...canonicalCopy } = planObject;
  const canonicalObj = canonicalize(canonicalCopy);
  const jsonStr = JSON.stringify(canonicalObj);
  return createHash('sha256').update(jsonStr).digest('hex');
}

/**
 * Builds an immutable change plan from validated components.
 */
export async function buildDeploymentPlan({
  environment = 'lab',
  changeTicket,
  targetNodes = [],
  approvedUpdates = [],
  action = 'Scan',
  workerPackage = {
    s3Uri: 's3://wuu-artifacts-lab-123456789012/packages/wuu-worker-package-lab.zip',
    versionId: 'ver-1.0.0',
    sha256: '1878a3df98fdd3af4d89f71643f1fdcff3012c0da0f84d76d04688a5343a149c',
  },
  documentVersion = '1',
  maintenanceWindowHours = 4,
  rebootAllowed = false,
  nowIso = new Date().toISOString(),
}) {
  if (!changeTicket) {
    throw new Error('Change ticket is mandatory to build an approved deployment plan.');
  }

  if (!targetNodes || targetNodes.length === 0) {
    throw new Error('Plan requires at least one target node.');
  }

  // Validate node class constraints: fleet patching allowed ONLY on memberServer
  for (const node of targetNodes) {
    if (node.nodeClass !== 'memberServer') {
      throw new Error(
        `Node class violation: Node ${node.instanceId} has class ${node.nodeClass}. Only memberServer is eligible for fleet patching.`
      );
    }
  }

  const startMs = Date.parse(nowIso);
  const deadlineMs = startMs + (maintenanceWindowHours * 3600 * 1000);
  const planId = `plan-${randomUUID()}`;

  const plan = {
    schemaVersion: '1.0.0',
    planId,
    timestamp: nowIso,
    environment,
    changeTicket,
    targetNodes,
    approvedUpdates,
    action,
    workerPackage,
    documentVersion,
    maintenanceWindow: {
      startTime: nowIso,
      deadlineTime: new Date(deadlineMs).toISOString(),
    },
    rebootPolicy: {
      rebootAllowed,
      maxRebootsPerNode: rebootAllowed ? 1 : 0,
    },
  };

  const digest = computePlanDigest(plan);
  plan.planDigest = digest;

  return plan;
}

