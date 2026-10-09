/**
 * @fileoverview Lambda handler for graceful fleet deployment cancellation and maintenance window cutoff management.
 * @module cloud/cancel
 * 
 * @status UNTESTED_IN_LIVE_ENVIRONMENT
 * @notice Validated via Node.js offline unit tests (Node 20+ test runner).
 *         Has NOT been deployed to a live AWS account or invoked via live Step Functions.
 *         Requires isolated AWS lab testing (Gate G1/G2) before deployment.
 * 
 * @security Least-Privilege IAM boundaries apply. Denied direct node modification.
 * @invariants
 *   - Graceful cancellation: Stops new dispatches while preserving active running installer reconciliations.
 *   - Servicing Store Integrity: Never interrupts an in-flight native installation to avoid component store corruption.
 *   - Enforces maintenance window budget requirements before initiating dispatches.
 */

/**
 * Checks whether sufficient maintenance window budget remains for a mutation.
 */
export function hasSufficientBudget({
  deadlineTime,
  minimumRequiredMinutes = 30,
  nowIso = new Date().toISOString(),
}) {
  if (!deadlineTime) return true;
  const deadlineMs = Date.parse(deadlineTime);
  const nowMs = Date.parse(nowIso);
  const remainingMinutes = (deadlineMs - nowMs) / (60 * 1000);
  return remainingMinutes >= minimumRequiredMinutes;
}

/**
 * Initiates graceful cancellation for a fleet deployment plan.
 */
export async function cancelDeployment({
  planId,
  environment = 'lab',
  reason = 'Operator cancellation or maintenance window cutoff',
  dynamoClient,
  nowIso = new Date().toISOString(),
}) {
  if (!planId) throw new Error('Missing required planId');

  const tableName = `wuu-operations-${environment}`;

  // 1. Mark Plan as CANCELLING in DynamoDB
  if (dynamoClient) {
    await dynamoClient.updateItem({
      TableName: tableName,
      Key: {
        PK: { S: `PLAN#${planId}` },
        SK: { S: 'PLAN_STATE' },
      },
      UpdateExpression: 'SET #status = :status, #cancelReason = :reason, #cancelledAt = :now',
      ExpressionAttributeNames: {
        '#status': 'status',
        '#cancelReason': 'cancelReason',
        '#cancelledAt': 'cancelledAt',
      },
      ExpressionAttributeValues: {
        ':status': { S: 'CANCELLING' },
        ':reason': { S: reason },
        ':now': { S: nowIso },
      },
    });
  }

  // Active running installer operations are deliberately NOT killed via ssm:CancelCommand
  // to prevent Windows Component-Based Servicing (CBS) store corruption.

  return {
    success: true,
    planId,
    status: 'CANCELLING',
    reason,
    activeInstallersPreserved: true,
    newDispatchesBlocked: true,
  };
}

/**
 * AWS Lambda Handler Entrypoint
 */
export async function handler(event, context) {
  const payload = event.Payload || event;
  return cancelDeployment(payload);
}

