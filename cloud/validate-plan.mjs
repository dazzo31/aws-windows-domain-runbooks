/**
 * @file validate-plan.mjs
 * @description Post-approval plan validator. Re-checks cryptographic digest,
 * maintenance window deadlines, and node class eligibility prior to dispatch.
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

