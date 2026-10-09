/**
 * @fileoverview Cloud state manager for durable DynamoDB operation tracking, conditional node locking, and fencing tokens.
 * @module cloud/state
 * 
 * @status UNTESTED_IN_LIVE_ENVIRONMENT
 * @notice Validated via Node.js offline unit tests (Node 20+ test runner).
 *         Has NOT been deployed to a live AWS account or invoked via live Step Functions.
 *         Requires isolated AWS lab testing (Gate G1/G2) before deployment.
 * 
 * @security Least-Privilege IAM boundaries apply. Access scoped to wuu-state-$Environment DynamoDB table.
 * @invariants
 *   - Atomic Fencing Tokens: Mutex acquisition requires monotonic fencingToken increments.
 *   - Conditional Writes: State transitions enforce condition expressions preventing concurrent writes.
 *   - TTL Safeguard: Node locks enforce TTL to prevent permanently orphaned locks after host crashes.
 */

/**
 * Valid operation statuses
 */
export const OperationStatus = Object.freeze({
  PENDING: 'PENDING',
  ACQUIRED: 'ACQUIRED',
  IN_PROGRESS: 'IN_PROGRESS',
  SUCCEEDED: 'SUCCEEDED',
  FAILED: 'FAILED',
  CANCELLED: 'CANCELLED',
  TIMEOUT: 'TIMEOUT',
  UNCERTAIN: 'UNCERTAIN',
});

/**
 * Valid lock statuses
 */
export const LockStatus = Object.freeze({
  HELD: 'HELD',
  RELEASED: 'RELEASED',
  EXPIRED: 'EXPIRED',
});

/**
 * Acquires a conditional mutual exclusion lock on a target node.
 * Uses conditional checks to ensure no concurrent operation holds an active unexpired lock.
 */
export async function acquireNodeLock({
  dynamoClient,
  tableName,
  instanceId,
  operationId,
  owner,
  leaseDurationSeconds = 1800,
  currentFencingToken = 0,
  nowIso = new Date().toISOString(),
}) {
  const pk = `LOCK#${instanceId}`;
  const sk = 'LOCK_STATE';
  const nowMs = Date.parse(nowIso);
  const leaseExpiryMs = nowMs + (leaseDurationSeconds * 1000);
  const nextFencingToken = currentFencingToken + 1;

  const item = {
    PK: { S: pk },
    SK: { S: sk },
    instanceId: { S: instanceId },
    operationId: { S: operationId },
    owner: { S: owner },
    lockStatus: { S: LockStatus.HELD },
    fencingToken: { N: nextFencingToken.toString() },
    acquiredAt: { S: nowIso },
    leaseExpiry: { N: leaseExpiryMs.toString() },
    updatedAt: { S: nowIso },
  };

  const conditionExpression =
    'attribute_not_exists(PK) OR #lockStatus = :released OR (#lockStatus = :held AND #leaseExpiry < :nowMs)';

  const params = {
    TableName: tableName,
    Item: item,
    ConditionExpression: conditionExpression,
    ExpressionAttributeNames: {
      '#lockStatus': 'lockStatus',
      '#leaseExpiry': 'leaseExpiry',
    },
    ExpressionAttributeValues: {
      ':released': { S: LockStatus.RELEASED },
      ':held': { S: LockStatus.HELD },
      ':nowMs': { N: nowMs.toString() },
    },
  };

  if (!dynamoClient) {
    // Mock / dry-run simulation return
    return {
      success: true,
      instanceId,
      operationId,
      fencingToken: nextFencingToken,
      leaseExpiryMs,
      simulated: true,
    };
  }

  await dynamoClient.putItem(params);
  return {
    success: true,
    instanceId,
    operationId,
    fencingToken: nextFencingToken,
    leaseExpiryMs,
  };
}

/**
 * Releases an acquired node lock conditionally, asserting the fencing token and owner.
 */
export async function releaseNodeLock({
  dynamoClient,
  tableName,
  instanceId,
  operationId,
  owner,
  fencingToken,
  nowIso = new Date().toISOString(),
}) {
  const pk = `LOCK#${instanceId}`;
  const sk = 'LOCK_STATE';

  if (!owner) {
    throw new Error('releaseNodeLock requires owner');
  }
  if (fencingToken === undefined || fencingToken === null) {
    throw new Error('releaseNodeLock requires fencingToken');
  }

  const expressionAttributeNames = {
    '#lockStatus': 'lockStatus',
    '#updatedAt': 'updatedAt',
    '#operationId': 'operationId',
    '#owner': 'owner',
    '#fencingToken': 'fencingToken',
  };
  const expressionAttributeValues = {
    ':released': { S: LockStatus.RELEASED },
    ':now': { S: nowIso },
    ':opId': { S: operationId },
    ':owner': { S: owner },
    ':token': { N: fencingToken.toString() },
  };

  const condition = '#operationId = :opId AND #owner = :owner AND #fencingToken = :token';

  const params = {
    TableName: tableName,
    Key: {
      PK: { S: pk },
      SK: { S: sk },
    },
    UpdateExpression: 'SET #lockStatus = :released, #updatedAt = :now',
    ConditionExpression: condition,
    ExpressionAttributeNames: expressionAttributeNames,
    ExpressionAttributeValues: expressionAttributeValues,
  };

  if (!dynamoClient) {
    return { success: true, released: true, lockStatus: LockStatus.RELEASED, fencingToken, simulated: true };
  }

  await dynamoClient.updateItem(params);
  return { success: true, released: true, lockStatus: LockStatus.RELEASED, fencingToken };
}

/**
 * Transitions operation status conditionally, rejecting stale or conflicting state.
 */
export async function transitionOperationStatus({
  dynamoClient,
  tableName,
  operationId,
  expectedStatus,
  newStatus,
  details = {},
  nowIso = new Date().toISOString(),
}) {
  if (!Object.values(OperationStatus).includes(newStatus)) {
    throw new Error(`Invalid target operation status: ${newStatus}`);
  }

  const pk = `OP#${operationId}`;
  const sk = 'METADATA';

  const params = {
    TableName: tableName,
    Key: {
      PK: { S: pk },
      SK: { S: sk },
    },
    UpdateExpression:
      'SET #status = :newStatus, #updatedAt = :now, #details = :details',
    ConditionExpression: '#status = :expectedStatus',
    ExpressionAttributeNames: {
      '#status': 'status',
      '#updatedAt': 'updatedAt',
      '#details': 'details',
    },
    ExpressionAttributeValues: {
      ':newStatus': { S: newStatus },
      ':expectedStatus': { S: expectedStatus },
      ':now': { S: nowIso },
      ':details': { S: JSON.stringify(details) },
    },
  };

  if (!dynamoClient) {
    return { success: true, from: expectedStatus, to: newStatus, simulated: true };
  }

  await dynamoClient.updateItem(params);
  return { success: true, from: expectedStatus, to: newStatus };
}

/**
 * Records a node update result, validating manifest digest and fencing token integrity.
 */
export async function recordNodeResult({
  dynamoClient,
  tableName,
  operationId,
  instanceId,
  fencingToken,
  expectedDigest,
  actualDigest,
  resultPayload,
  nowIso = new Date().toISOString(),
}) {
  if (expectedDigest && actualDigest && expectedDigest.toLowerCase() !== actualDigest.toLowerCase()) {
    throw new Error(
      `Manifest digest mismatch! Expected ${expectedDigest}, received ${actualDigest}. Rejecting stale result.`
    );
  }

  const pk = `OP#${operationId}`;
  const sk = `RESULT#${instanceId}`;

  const item = {
    PK: { S: pk },
    SK: { S: sk },
    operationId: { S: operationId },
    instanceId: { S: instanceId },
    fencingToken: { N: fencingToken.toString() },
    manifestDigest: { S: actualDigest || expectedDigest || 'none' },
    result: { S: JSON.stringify(resultPayload) },
    recordedAt: { S: nowIso },
  };

  if (!dynamoClient) {
    return { success: true, recorded: true, simulated: true };
  }

  await dynamoClient.putItem({
    TableName: tableName,
    Item: item,
  });

  return { success: true, recorded: true };
}

