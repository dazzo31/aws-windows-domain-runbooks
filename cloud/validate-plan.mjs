/**
 * @fileoverview Post-approval plan validator re-checking cryptographic digest, deadlines, and node eligibility.
 * @module cloud/validate-plan
 * 
 * @status UNTESTED_IN_LIVE_ENVIRONMENT
 * @notice Validated via Node.js offline unit tests (Node 20+ test runner).
 *         Has NOT been deployed to a live AWS account or invoked via live Step Functions.
 *         Requires isolated AWS lab testing (Gate G1/G2) before deployment.
 * 
 * @security Least-Privilege IAM boundaries apply. Denied direct node modification.
 * @invariants
 *   - Cryptographic Integrity: Computes planDigest and verifies match against approved plan.
 *   - Maintenance Window Enforcement: Rejects plans whose maintenance window deadline has elapsed.
 *   - Class Validation: Verifies every targeted node belongs to an approved nodeClass.
 */

import { computePlanDigest } from './build-plan.mjs';

/**
 * Validates a change plan post-approval.
 */
export function validateDeploymentPlan(plan, nowIso = new Date().toISOString()) {
  if (!plan || !plan.planId) {
    throw new Error('Invalid plan: missing plan object or planId.');
  }

  // 1. Digest Integrity Verification (Anti-Tampering)
  const expectedDigest = plan.planDigest;
  const actualDigest = computePlanDigest(plan);
  if (expectedDigest !== actualDigest) {
    throw new Error(
      `Plan tampering detected! Expected digest ${expectedDigest}, recomputed digest ${actualDigest}. Plan invalidated.`
    );
  }

  // 2. Maintenance Window Validation
  const nowMs = Date.parse(nowIso);
  const deadlineMs = Date.parse(plan.maintenanceWindow.deadlineTime);
  if (nowMs > deadlineMs) {
    throw new Error(
      `Maintenance window expired! Current time (${nowIso}) exceeds plan deadline (${plan.maintenanceWindow.deadlineTime}).`
    );
  }

  // 3. Node Class Invariant Check
  for (const node of plan.targetNodes) {
    if (node.nodeClass !== 'memberServer') {
      throw new Error(
        `Tier 0 Violation: Node ${node.instanceId} has prohibited class ${node.nodeClass} in fleet plan.`
      );
    }
  }

  return {
    valid: true,
    planId: plan.planId,
    changeTicket: plan.changeTicket,
    nodeCount: plan.targetNodes.length,
    planDigest: actualDigest,
  };
}

