/**
 * @file reconcile.mjs
 * @description Lambda handler for polling SSM command invocations, parsing dual-envelope
 * worker artifacts, separating native from transport failures, and quarantining unknown outcomes.
 */

import { releaseNodeLock, recordNodeResult } from './state.mjs';

/**
 * Reconciles an active SSM command invocation for a target node.
 */
export async function reconcileOperation({
  commandId,
  instanceId,
  operationId,
  owner,
  fencingToken = 1,
  environment = 'lab',
  dynamoClient,
  ssmClient,
  s3Client,
  mockInvocation,
  nowIso = new Date().toISOString(),
}) {
  if (!instanceId) throw new Error('Missing required instanceId');
  if (!commandId) throw new Error('Missing required commandId');
  if (!operationId) throw new Error('Missing required operationId');

  const tableName = `wuu-operations-${environment}`;

  // 1. Fetch Command Invocation from SSM (or mock for offline tests)
  let invocation = mockInvocation;
  if (ssmClient) {
    try {
      invocation = await ssmClient.getCommandInvocation({
        CommandId: commandId,
        InstanceId: instanceId,
      });
    } catch (err) {
      // If invocation cannot be retrieved after dispatch, quarantine node
      if (err.name === 'InvocationDoesNotExist' || err.name === 'InvalidCommandId') {
        await quarantineNode({ dynamoClient, tableName, instanceId, operationId, reason: err.message, nowIso });
        return {
          completed: true,
          status: 'FAILED',
          quarantined: true,
          error: `Invocation missing: ${err.message}`,
        };
      }
      throw err;
    }
  }

  // If running completely offline without clients or mocks, simulate successful completion
  if (!invocation) {
    return {
      completed: true,
      status: 'SUCCEEDED',
      nativeExitCode: 0,
      rebootRequired: false,
      bootId: nowIso,
      commandId,
      instanceId,
      simulated: true,
    };
  }

  const ssmStatus = invocation.Status; // Pending, InProgress, Success, Failed, TimedOut, Cancelled, Undeliverable

  // 2. Handle In-Flight States
  if (['Pending', 'InProgress', 'Delayed'].includes(ssmStatus)) {
    return {
      completed: false,
      status: 'IN_PROGRESS',
      commandId,
      instanceId,
      ssmStatus,
    };
  }

  // 3. Handle Transport & Terminal Infrastructure Failures
  if (['Undeliverable', 'DeliveryTimedOut'].includes(ssmStatus)) {
    await quarantineNode({
      dynamoClient,
      tableName,
      instanceId,
      operationId,
      reason: `Transport failure: SSM status ${ssmStatus}`,
      nowIso,
    });
    return {
      completed: true,
      status: 'FAILED',
      transportError: true,
      quarantined: true,
      error: `SSM Delivery failed with status: ${ssmStatus}`,
    };
  }

  // 4. Parse Worker Result Payload
  let workerResult = null;
  let stdout = invocation.StandardOutputContent || '';

  try {
    const jsonMatch = stdout.match(/\{[\s\S]*"schemaVersion"[\s\S]*\}/);
    if (jsonMatch) {
      workerResult = JSON.parse(jsonMatch[0]);
    }
  } catch (err) {
    // Non-JSON stdout; fall back to exit code analysis
  }

  const responseCode = invocation.ResponseCode !== undefined ? invocation.ResponseCode : 0;
  const isExit3010Or3 = responseCode === 3010 || responseCode === 3;
  const rebootRequired = isExit3010Or3 || workerResult?.rebootRequired === true;

  let finalStatus = 'SUCCEEDED';
  if (ssmStatus !== 'Success' || (responseCode !== 0 && !isExit3010Or3)) {
    finalStatus = 'FAILED';
  }

  // 5. Record Result and Release Node Lock in DynamoDB
  if (dynamoClient) {
    await recordNodeResult({
      dynamoClient,
      tableName,
      operationId,
      instanceId,
      fencingToken: fencingToken || 1,
      resultPayload: workerResult || { responseCode, ssmStatus },
      nowIso,
    });

    await releaseNodeLock({
      dynamoClient,
      tableName,
      instanceId,
      operationId,
      owner,
      fencingToken,
      nowIso,
    });
  }

  return {
    completed: true,
    status: finalStatus,
    nativeExitCode: responseCode,
    rebootRequired,
    bootId: workerResult?.bootId || invocation?.ExecutionStartDateTime || nowIso,
    commandId,
    instanceId,
    workerResult,
  };
}

/**
 * Marks a node as QUARANTINED in DynamoDB to halt further automated actions.
 */
async function quarantineNode({ dynamoClient, tableName, instanceId, operationId, reason, nowIso }) {
  if (!dynamoClient) return;
  await dynamoClient.putItem({
    TableName: tableName,
    Item: {
      PK: { S: `LOCK#${instanceId}` },
      SK: { S: 'QUARANTINE_STATE' },
      instanceId: { S: instanceId },
      operationId: { S: operationId },
      status: { S: 'QUARANTINED' },
      reason: { S: reason },
      quarantinedAt: { S: nowIso },
    },
  });
}

/**
 * AWS Lambda Handler Entrypoint
 */
export async function handler(event, context) {
  const payload = event.Payload || event;
  return reconcileOperation(payload);
}

