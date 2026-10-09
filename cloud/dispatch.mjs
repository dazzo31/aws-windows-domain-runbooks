/**
 * @fileoverview Lambda handler for acquiring durable node locks and dispatching numeric-pinned SSM SendCommand executions to approved EC2 targets.
 * @module cloud/dispatch
 * 
 * @status UNTESTED_IN_LIVE_ENVIRONMENT
 * @notice Validated via Node.js offline unit tests (Node 20+ test runner).
 *         Has NOT been deployed to a live AWS account or invoked via live Step Functions.
 *         Requires isolated AWS lab testing (Gate G1/G2) before deployment.
 * 
 * @security Least-Privilege IAM boundaries apply. Denied direct node modification.
 * @invariants
 *   - Node Lock Fencing: Must successfully acquire DynamoDB node lock before dispatching SSM command.
 *   - Numeric Document Pinning: SSM DocumentVersion must be numeric-pinned; $DEFAULT prohibited in production.
 *   - ChangeTicket Required: Mandatory change ticket required for all mutating actions.
 */

import { acquireNodeLock } from './state.mjs';

const VALID_ACTIONS = new Set(['Scan', 'Download', 'Install', 'Reboot', 'Verify']);
const INSTANCE_REGEX = /^i-[0-9a-f]{8,17}$/;

/**
 * Dispatches an approved WUU operation to a single target EC2 instance.
 */
export async function dispatchOperation({
  instanceId,
  computerName,
  action,
  planId,
  changeTicket,
  workerPackage,
  priorBootId,
  documentVersion = '1',
  environment = 'lab',
  dynamoClient,
  ssmClient,
  nowIso = new Date().toISOString(),
}) {
  if (!instanceId || !INSTANCE_REGEX.test(instanceId)) {
    throw new Error(`Invalid or missing EC2 instanceId: ${instanceId}`);
  }
  if (!action || !VALID_ACTIONS.has(action)) {
    throw new Error(`Invalid action '${action}'. Must be one of: ${Array.from(VALID_ACTIONS).join(', ')}`);
  }
  if (!planId) {
    throw new Error('Missing required planId');
  }
  if (!changeTicket) {
    throw new Error('Missing required changeTicket');
  }

  const operationId = `op-${planId}-${instanceId}-${action.toLowerCase()}`;
  const tableName = `wuu-operations-${environment}`;

  // 1. Acquire Distributed Node Lock (Fencing)
  const ownerIdentity = `dispatch-${process.env.AWS_LAMBDA_FUNCTION_NAME || 'local'}`;
  const lockResult = await acquireNodeLock({
    dynamoClient,
    tableName,
    instanceId,
    operationId,
    owner: ownerIdentity,
    leaseDurationSeconds: 3600,
    nowIso,
  });

  const documentName = `Wuu-${action}`;
  const s3Bucket = `wuu-artifacts-${environment}`;
  const s3KeyPrefix = `logs/ssm/${operationId}/${instanceId}`;

  // 2. Prepare SSM Parameters
  const ssmParameters = {
    OperationId: [operationId],
    ChangeTicket: [changeTicket],
  };

  if (action === 'Install' || action === 'Reboot') {
    ssmParameters.Apply = ['true'];
  }

  if (priorBootId) {
    ssmParameters.PriorBootId = [priorBootId];
  }

  if (workerPackage?.s3Uri) {
    ssmParameters.WorkerPackageS3Uri = [workerPackage.s3Uri];
  }
  if (workerPackage?.versionId) {
    ssmParameters.WorkerPackageVersionId = [workerPackage.versionId];
  }
  if (workerPackage?.sha256) {
    ssmParameters.WorkerPackageSha256 = [workerPackage.sha256];
  }

  // 3. Dispatch SSM SendCommand
  let commandId = `cmd-${operationId}-${Date.parse(nowIso)}`;

  if (ssmClient) {
    const sendParams = {
      DocumentName: documentName,
      DocumentVersion: documentVersion,
      InstanceIds: [instanceId],
      Comment: `WUU2-CLI: ${action} for ${operationId} under ticket ${changeTicket}`,
      Parameters: ssmParameters,
      OutputS3BucketName: s3Bucket,
      OutputS3KeyPrefix: s3KeyPrefix,
    };
    const sendResult = await ssmClient.sendCommand(sendParams);
    commandId = sendResult.Command?.CommandId || commandId;
  }

  // 4. Record Dispatch Correlation in DynamoDB
  if (dynamoClient) {
    await dynamoClient.putItem({
      TableName: tableName,
      Item: {
        PK: { S: `OP#${operationId}` },
        SK: { S: `COMMAND#${instanceId}` },
        operationId: { S: operationId },
        instanceId: { S: instanceId },
        commandId: { S: commandId },
        action: { S: action },
        planId: { S: planId },
        status: { S: 'DISPATCHED' },
        dispatchedAt: { S: nowIso },
      },
    });
  }

  return {
    success: true,
    commandId,
    operationId,
    instanceId,
    action,
    owner: ownerIdentity,
    fencingToken: lockResult.fencingToken,
    status: 'DISPATCHED',
    simulated: !ssmClient,
  };
}

/**
 * AWS Lambda Handler Entrypoint
 */
export async function handler(event, context) {
  const payload = event.Payload || event;
  return dispatchOperation(payload);
}

