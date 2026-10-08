// Validates planning traceability checkpoints and environment configuration templates offline.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const YAML = require('yaml');

const root = path.join(__dirname, '..');

// 1. Verify planning documentation existence
const planPath = path.join(root, 'planning', 'aws-integration', 'plan.md');
assert.ok(fs.existsSync(planPath), 'Missing plan.md');
const planContent = fs.readFileSync(planPath, 'utf8');
assert.ok(planContent.length > 1000, 'plan.md is too short or empty');

// 2. Validate spec-to-plan traceability checkpoint
const specToPlanPath = path.join(root, 'planning', 'aws-integration', 'checkpoints', 'spec-to-plan.yaml');
assert.ok(fs.existsSync(specToPlanPath), 'Missing spec-to-plan.yaml checkpoint');
const specToPlanDoc = YAML.parse(fs.readFileSync(specToPlanPath, 'utf8'));
assert.equal(specToPlanDoc.summary.missing_requirements, 0, 'spec-to-plan has missing requirements');
assert.equal(specToPlanDoc.summary.covered_requirements, 20, 'spec-to-plan must cover exactly 20 requirements');
assert.equal(specToPlanDoc.summary.coverage_percentage, 100.0, 'spec-to-plan coverage must be 100%');
assert.equal(specToPlanDoc.validation.passed, true, 'spec-to-plan validation must be passed');
assert.equal(specToPlanDoc.requirements.length, 20, 'spec-to-plan must list 20 requirements');

// 3. Validate plan-to-tasks traceability checkpoint
const planToTasksPath = path.join(root, 'planning', 'aws-integration', 'checkpoints', 'plan-to-tasks.yaml');
assert.ok(fs.existsSync(planToTasksPath), 'Missing plan-to-tasks.yaml checkpoint');
const planToTasksDoc = YAML.parse(fs.readFileSync(planToTasksPath, 'utf8'));
assert.equal(planToTasksDoc.summary.missing_plan_items, 0, 'plan-to-tasks has missing plan items');
assert.equal(planToTasksDoc.summary.covered_plan_items, 15, 'plan-to-tasks must cover exactly 15 plan items');
assert.equal(planToTasksDoc.summary.total_tasks_generated, 62, 'plan-to-tasks must cover exactly 62 tasks');
assert.equal(planToTasksDoc.summary.orphan_tasks, 0, 'plan-to-tasks must have 0 orphan tasks');
assert.equal(planToTasksDoc.validation.passed, true, 'plan-to-tasks validation must be passed');

// 4. Validate environment template configuration and schema
const envSchemaPath = path.join(root, 'schemas', 'environment.schema.json');
assert.ok(fs.existsSync(envSchemaPath), 'Missing environment.schema.json');
const envSchema = JSON.parse(fs.readFileSync(envSchemaPath, 'utf8'));
assert.equal(envSchema.title, 'WuuEnvironmentConfiguration', 'Invalid schema title');

const envExamplePath = path.join(root, 'config', 'environments', 'lab.example.yaml');
assert.ok(fs.existsSync(envExamplePath), 'Missing lab.example.yaml template');
const envExampleDoc = YAML.parse(fs.readFileSync(envExamplePath, 'utf8'));
assert.equal(envExampleDoc.schemaVersion, '1.0.0', 'Invalid lab.example.yaml schemaVersion');
assert.equal(envExampleDoc.status, 'template', 'lab.example.yaml must have status: template');
assert.equal(envExampleDoc.upstream.project, 'WUU2-CLI', 'Upstream project must be WUU2-CLI');
assert.ok(envExampleDoc.upstream.pinnedCommit, 'Upstream pinned commit must be specified');
assert.equal(envExampleDoc.wsus.authorityOnly, true, 'WSUS must be authorityOnly');
assert.equal(envExampleDoc.wsus.allowMicrosoftUpdateFallback, false, 'Microsoft Update fallback must be prohibited');
assert.equal(envExampleDoc.wsus.allowPatchManager, false, 'AWS Patch Manager must be prohibited');
assert.equal(envExampleDoc.nodeClasses.domainController.eligibleForFleetPatching, false, 'DCs must be excluded from fleet patching');

// 5. Validate upstream integration contract documentation
const integrationDocPath = path.join(root, 'integrations', 'WUU2-CLI.md');
assert.ok(fs.existsSync(integrationDocPath), 'Missing integrations/WUU2-CLI.md');
const integrationDoc = fs.readFileSync(integrationDocPath, 'utf8');
assert.ok(integrationDoc.includes('Decoupled Consumer Model'), 'WUU2-CLI.md must document Decoupled Consumer Model');
assert.ok(integrationDoc.includes('e81b620905d549783d7e17498a0b3cbbcf5f4095'), 'WUU2-CLI.md must cite pinned commit');
assert.ok(integrationDoc.includes('v1.5.0-rc.4-cli'), 'WUU2-CLI.md must cite pinned tag');

// 6. Validate infra/network.yaml CloudFormation template
const networkPath = path.join(root, 'infra', 'network.yaml');
assert.ok(fs.existsSync(networkPath), 'Missing infra/network.yaml');
const networkContent = fs.readFileSync(networkPath, 'utf8');
assert.ok(networkContent.includes('SsmInterfaceEndpoint'), 'network.yaml must define SsmInterfaceEndpoint');
assert.ok(networkContent.includes('SsmMessagesInterfaceEndpoint'), 'network.yaml must define SsmMessagesInterfaceEndpoint');
assert.ok(networkContent.includes('S3GatewayEndpoint'), 'network.yaml must define S3GatewayEndpoint');
assert.ok(networkContent.includes('EnableEc2Messages'), 'network.yaml must support conditional Ec2Messages');
assert.ok(networkContent.includes('EndpointSecurityGroup'), 'network.yaml must define EndpointSecurityGroup');

// 7. Validate T006: Test-NodeConnectivity.ps1 and runbooks/NETWORK.md
const nodeConnScriptPath = path.join(root, 'scripts', 'Test-NodeConnectivity.ps1');
assert.ok(fs.existsSync(nodeConnScriptPath), 'Missing scripts/Test-NodeConnectivity.ps1');
const nodeConnScript = fs.readFileSync(nodeConnScriptPath, 'utf8');
assert.ok(nodeConnScript.includes('OfflineMode'), 'Test-NodeConnectivity.ps1 must support OfflineMode');
assert.ok(nodeConnScript.includes('8531'), 'Test-NodeConnectivity.ps1 must validate port 8531 for WSUS');

const networkDocPath = path.join(root, 'runbooks', 'NETWORK.md');
assert.ok(fs.existsSync(networkDocPath), 'Missing runbooks/NETWORK.md');
const networkDoc = fs.readFileSync(networkDocPath, 'utf8');
assert.ok(networkDoc.includes('Conditional Forwarder'), 'NETWORK.md must document AD DNS conditional forwarding');
assert.ok(networkDoc.includes('AmazonProvidedDNS'), 'NETWORK.md must document AmazonProvidedDNS');
assert.ok(networkDoc.includes('8531'), 'NETWORK.md must document WSUS port 8531');
assert.ok(networkDoc.includes('No Inbound DCOM/WinRM for SSM'), 'NETWORK.md must document no inbound DCOM/WinRM for SSM');

// 8. Validate T007: documents/Wuu-Bootstrap.yaml
const bootstrapDocPath = path.join(root, 'documents', 'Wuu-Bootstrap.yaml');
assert.ok(fs.existsSync(bootstrapDocPath), 'Missing documents/Wuu-Bootstrap.yaml');
const bootstrapDoc = YAML.parse(fs.readFileSync(bootstrapDocPath, 'utf8'));
assert.equal(bootstrapDoc.schemaVersion, '2.2', 'Wuu-Bootstrap.yaml must use schemaVersion 2.2');
assert.ok(bootstrapDoc.parameters.Action, 'Wuu-Bootstrap.yaml must define Action parameter');
assert.ok(bootstrapDoc.parameters.Apply, 'Wuu-Bootstrap.yaml must define Apply parameter');
assert.ok(bootstrapDoc.parameters.ChangeTicket, 'Wuu-Bootstrap.yaml must define ChangeTicket parameter');

// 9. Validate T008: documents/Wuu-Inventory.yaml and schemas/node-inventory.schema.json
const inventorySchemaPath = path.join(root, 'schemas', 'node-inventory.schema.json');
assert.ok(fs.existsSync(inventorySchemaPath), 'Missing schemas/node-inventory.schema.json');
const inventorySchema = JSON.parse(fs.readFileSync(inventorySchemaPath, 'utf8'));
assert.equal(inventorySchema.title, 'WuuNodeInventory', 'Invalid node-inventory schema title');
assert.ok(inventorySchema.properties.ec2, 'node-inventory schema must include ec2 object');
assert.ok(inventorySchema.properties.node, 'node-inventory schema must include node object');
assert.ok(inventorySchema.properties.eligibility, 'node-inventory schema must include eligibility object');

const inventoryDocPath = path.join(root, 'documents', 'Wuu-Inventory.yaml');
assert.ok(fs.existsSync(inventoryDocPath), 'Missing documents/Wuu-Inventory.yaml');
const inventoryDoc = YAML.parse(fs.readFileSync(inventoryDocPath, 'utf8'));
assert.equal(inventoryDoc.schemaVersion, '2.2', 'Wuu-Inventory.yaml must use schemaVersion 2.2');
assert.ok(inventoryDoc.parameters.ExpectedDomain, 'Wuu-Inventory.yaml must define ExpectedDomain');
assert.ok(inventoryDoc.parameters.AssignedPhase, 'Wuu-Inventory.yaml must define AssignedPhase');

// 10. Validate Plan 2.1 Identity and Secrets Infrastructure (T009-T011)
const iamPath = path.join(root, 'infra', 'iam.yaml');
assert.ok(fs.existsSync(iamPath), 'Missing infra/iam.yaml');
const iamContent = fs.readFileSync(iamPath, 'utf8');
assert.ok(iamContent.includes('WuuOperatorRole'), 'iam.yaml must define WuuOperatorRole');
assert.ok(iamContent.includes('WuuApproverRole'), 'iam.yaml must define WuuApproverRole');
assert.ok(iamContent.includes('WuuCoordinatorRole'), 'iam.yaml must define WuuCoordinatorRole');
assert.ok(iamContent.includes('WuuManagedNodeRole'), 'iam.yaml must define WuuManagedNodeRole');
assert.ok(iamContent.includes('WuuAdPasswordWorkerRole'), 'iam.yaml must define WuuAdPasswordWorkerRole');

const secretsInfraPath = path.join(root, 'infra', 'secrets.yaml');
assert.ok(fs.existsSync(secretsInfraPath), 'Missing infra/secrets.yaml');
const secretsInfraContent = fs.readFileSync(secretsInfraPath, 'utf8');
assert.ok(secretsInfraContent.includes('WuuKmsKey'), 'secrets.yaml must define WuuKmsKey');
assert.ok(secretsInfraContent.includes('AllowDecryptionOnlyToAdPasswordWorkerViaSsm'), 'secrets.yaml must restrict decryption to password worker');
assert.ok(secretsInfraContent.includes('MultiRegion: true'), 'secrets.yaml must enable MultiRegion on KMS key (F5)');
assert.ok(secretsInfraContent.includes('EnableKeyRotation: true'), 'secrets.yaml must enable key rotation on KMS key (F5)');

const secretsRunbookPath = path.join(root, 'runbooks', 'SECRETS.md');
assert.ok(fs.existsSync(secretsRunbookPath), 'Missing runbooks/SECRETS.md');
const secretsRunbookContent = fs.readFileSync(secretsRunbookPath, 'utf8');
assert.ok(secretsRunbookContent.includes('TIER 0 CREDENTIAL BOUNDARY'), 'SECRETS.md must define credential boundary');

// 11. Validate Plan 2.1 Authorization Matrix and Testing (T012)
const authMatrixPath = path.join(root, 'security', 'authorization-matrix.md');
assert.ok(fs.existsSync(authMatrixPath), 'Missing security/authorization-matrix.md');
const authMatrixContent = fs.readFileSync(authMatrixPath, 'utf8');
assert.ok(authMatrixContent.includes('Comprehensive Role Authorization Matrix'), 'authorization-matrix.md must include matrix');

const authScriptPath = path.join(root, 'scripts', 'Test-AwsAuthorization.ps1');
assert.ok(fs.existsSync(authScriptPath), 'Missing scripts/Test-AwsAuthorization.ps1');
const authScriptContent = fs.readFileSync(authScriptPath, 'utf8');
assert.ok(authScriptContent.includes('OfflineMode'), 'Test-AwsAuthorization.ps1 must support OfflineMode');

// 12. Validate Plan 2.2 Storage and Immutable Artifacts (T013-T016)
const storagePath = path.join(root, 'infra', 'storage.yaml');
assert.ok(fs.existsSync(storagePath), 'Missing infra/storage.yaml');
const storageContent = fs.readFileSync(storagePath, 'utf8');
assert.ok(storageContent.includes('ArtifactsBucket'), 'storage.yaml must define ArtifactsBucket');
assert.ok(storageContent.includes('AccessLogsBucket'), 'storage.yaml must define AccessLogsBucket');
assert.ok(storageContent.includes('EnforceTlsOnly'), 'storage.yaml must enforce TLS only');
assert.ok(storageContent.includes('ObjectLockEnabled'), 'storage.yaml must configure Object Lock (F4)');
assert.ok(storageContent.includes('ReplicationConfiguration'), 'storage.yaml must configure Cross-Region Replication (F4)');
assert.ok(storageContent.includes('EnforceTlsVersion'), 'storage.yaml must enforce TLS 1.2+ minimum protocol version (F4)');

const releaseSchemaPath = path.join(root, 'schemas', 'release-manifest.schema.json');
assert.ok(fs.existsSync(releaseSchemaPath), 'Missing schemas/release-manifest.schema.json');
const releaseSchema = JSON.parse(fs.readFileSync(releaseSchemaPath, 'utf8'));
assert.equal(releaseSchema.title, 'WuuReleaseManifest', 'Invalid release-manifest schema title');
assert.ok(releaseSchema.properties.upstream, 'release-manifest schema must include upstream');
assert.ok(releaseSchema.properties.package, 'release-manifest schema must include package');

const buildPkgScriptPath = path.join(root, 'scripts', 'Build-WorkerPackage.ps1');
assert.ok(fs.existsSync(buildPkgScriptPath), 'Missing scripts/Build-WorkerPackage.ps1');

const pubDocsScriptPath = path.join(root, 'scripts', 'Publish-Documents.ps1');
assert.ok(fs.existsSync(pubDocsScriptPath), 'Missing scripts/Publish-Documents.ps1');

const pubPkgScriptPath = path.join(root, 'scripts', 'Publish-WorkerPackage.ps1');
assert.ok(fs.existsSync(pubPkgScriptPath), 'Missing scripts/Publish-WorkerPackage.ps1');

const artifactsModulePath = path.join(root, 'workers', 'Wuu.Artifacts.psm1');
assert.ok(fs.existsSync(artifactsModulePath), 'Missing workers/Wuu.Artifacts.psm1');
const artifactsModuleContent = fs.readFileSync(artifactsModulePath, 'utf8');
assert.ok(artifactsModuleContent.includes('Expand-WuuWorkerPackage'), 'Wuu.Artifacts.psm1 must define Expand-WuuWorkerPackage');
assert.ok(artifactsModuleContent.includes('Test-WuuReparsePoint'), 'Wuu.Artifacts.psm1 must define Test-WuuReparsePoint');

// 13. Validate Plan 2.3 Operation and Lock Records (T017-T020)
const stateInfraPath = path.join(root, 'infra', 'state.yaml');
assert.ok(fs.existsSync(stateInfraPath), 'Missing infra/state.yaml');
const stateInfraContent = fs.readFileSync(stateInfraPath, 'utf8');
assert.ok(stateInfraContent.includes('OperationsTable'), 'state.yaml must define OperationsTable');
assert.ok(stateInfraContent.includes('PointInTimeRecoverySpecification'), 'state.yaml must enable PITR');

const opSchemaPath = path.join(root, 'schemas', 'operation.schema.json');
assert.ok(fs.existsSync(opSchemaPath), 'Missing schemas/operation.schema.json');
const opSchema = JSON.parse(fs.readFileSync(opSchemaPath, 'utf8'));
assert.equal(opSchema.title, 'WuuOperationRecord', 'Invalid operation schema title');
assert.ok(opSchema.properties.fencingToken, 'operation schema must include fencingToken');

const cloudStatePath = path.join(root, 'cloud', 'state.mjs');
assert.ok(fs.existsSync(cloudStatePath), 'Missing cloud/state.mjs');
const cloudStateContent = fs.readFileSync(cloudStatePath, 'utf8');
assert.ok(cloudStateContent.includes('acquireNodeLock'), 'state.mjs must define acquireNodeLock');
assert.ok(cloudStateContent.includes('releaseNodeLock'), 'state.mjs must define releaseNodeLock');
assert.ok(cloudStateContent.includes('recordNodeResult'), 'state.mjs must define recordNodeResult');

const localStatePath = path.join(root, 'workers', 'Wuu.LocalState.psm1');
assert.ok(fs.existsSync(localStatePath), 'Missing workers/Wuu.LocalState.psm1');
const localStateContent = fs.readFileSync(localStatePath, 'utf8');
assert.ok(localStateContent.includes('Enter-WuuServicingLock'), 'Wuu.LocalState.psm1 must define Enter-WuuServicingLock');
assert.ok(localStateContent.includes('Find-WuuAbandonedOperations'), 'Wuu.LocalState.psm1 must define Find-WuuAbandonedOperations');

const recoveryDocPath = path.join(root, 'runbooks', 'RECOVERY.md');
assert.ok(fs.existsSync(recoveryDocPath), 'Missing runbooks/RECOVERY.md');
const recoveryDocContent = fs.readFileSync(recoveryDocPath, 'utf8');
assert.ok(recoveryDocContent.includes('THE GOLDEN RULE OF SERVICING RECOVERY'), 'RECOVERY.md must include golden rule');

// 14. Validate Phase 3 Local WSUS Worker and Policy (T021-T028)
const localUpdatePath = path.join(root, 'workers', 'Wuu.LocalUpdate.psm1');
assert.ok(fs.existsSync(localUpdatePath), 'Missing workers/Wuu.LocalUpdate.psm1');
const localUpdateContent = fs.readFileSync(localUpdatePath, 'utf8');
assert.ok(localUpdateContent.includes('Search-WuuUpdates'), 'Wuu.LocalUpdate.psm1 must define Search-WuuUpdates');
assert.ok(localUpdateContent.includes('Download-WuuUpdates'), 'Wuu.LocalUpdate.psm1 must define Download-WuuUpdates');
assert.ok(localUpdateContent.includes('Install-WuuUpdates'), 'Wuu.LocalUpdate.psm1 must define Install-WuuUpdates');
assert.ok(localUpdateContent.includes('ServerSelection = 2'), 'Wuu.LocalUpdate.psm1 must enforce ServerSelection = 2');

const invokeWorkerPath = path.join(root, 'workers', 'Invoke-WuuWorker.ps1');
assert.ok(fs.existsSync(invokeWorkerPath), 'Missing workers/Invoke-WuuWorker.ps1');

const workerResultSchemaPath = path.join(root, 'schemas', 'worker-result.schema.json');
assert.ok(fs.existsSync(workerResultSchemaPath), 'Missing schemas/worker-result.schema.json');
const workerResultSchema = JSON.parse(fs.readFileSync(workerResultSchemaPath, 'utf8'));
assert.equal(workerResultSchema.title, 'WuuWorkerResult', 'Invalid worker-result schema title');

const wuuResultModulePath = path.join(root, 'workers', 'Wuu.Result.psm1');
assert.ok(fs.existsSync(wuuResultModulePath), 'Missing workers/Wuu.Result.psm1');

assert.ok(fs.existsSync(path.join(root, 'documents', 'Wuu-Scan.yaml')), 'Missing documents/Wuu-Scan.yaml');
assert.ok(fs.existsSync(path.join(root, 'documents', 'Wuu-Download.yaml')), 'Missing documents/Wuu-Download.yaml');
assert.ok(fs.existsSync(path.join(root, 'documents', 'Wuu-Install.yaml')), 'Missing documents/Wuu-Install.yaml');

const wsusPolicyPath = path.join(root, 'workers', 'Wuu.WsusPolicy.psm1');
assert.ok(fs.existsSync(wsusPolicyPath), 'Missing workers/Wuu.WsusPolicy.psm1');
const wsusPolicyContent = fs.readFileSync(wsusPolicyPath, 'utf8');
assert.ok(wsusPolicyContent.includes('Assert-WuuWsusAuthority'), 'Wuu.WsusPolicy.psm1 must define Assert-WuuWsusAuthority');

const updateSelectionSchemaPath = path.join(root, 'schemas', 'update-selection.schema.json');
assert.ok(fs.existsSync(updateSelectionSchemaPath), 'Missing schemas/update-selection.schema.json');

const wsusIntegDocPath = path.join(root, 'runbooks', 'WSUS-INTEGRATION.md');
assert.ok(fs.existsSync(wsusIntegDocPath), 'Missing runbooks/WSUS-INTEGRATION.md');

// 15. Validate Phase 4 Approval Entry and WUU Adapter (T029-T037)
const changePlanSchemaPath = path.join(root, 'schemas', 'change-plan.schema.json');
assert.ok(fs.existsSync(changePlanSchemaPath), 'Missing schemas/change-plan.schema.json');
const changePlanSchema = JSON.parse(fs.readFileSync(changePlanSchemaPath, 'utf8'));
assert.equal(changePlanSchema.title, 'WuuChangePlan', 'Invalid change-plan schema title');

const buildPlanPath = path.join(root, 'cloud', 'build-plan.mjs');
assert.ok(fs.existsSync(buildPlanPath), 'Missing cloud/build-plan.mjs');
const buildPlanContent = fs.readFileSync(buildPlanPath, 'utf8');
assert.ok(buildPlanContent.includes('buildDeploymentPlan'), 'build-plan.mjs must define buildDeploymentPlan');

const validatePlanPath = path.join(root, 'cloud', 'validate-plan.mjs');
assert.ok(fs.existsSync(validatePlanPath), 'Missing cloud/validate-plan.mjs');

const approvedDeployDocPath = path.join(root, 'documents', 'Wuu-ApprovedDeployment.yaml');
assert.ok(fs.existsSync(approvedDeployDocPath), 'Missing documents/Wuu-ApprovedDeployment.yaml');
const approvedDeployDoc = YAML.parse(fs.readFileSync(approvedDeployDocPath, 'utf8'));
assert.equal(approvedDeployDoc.schemaVersion, '0.3', 'Wuu-ApprovedDeployment.yaml must use schemaVersion 0.3');

const winDomainApprovedDocPath = path.join(root, 'documents', 'WinDomain-ApprovedChange.yaml');
assert.ok(fs.existsSync(winDomainApprovedDocPath), 'Missing documents/WinDomain-ApprovedChange.yaml');
const winDomainApprovedDoc = YAML.parse(fs.readFileSync(winDomainApprovedDocPath, 'utf8'));
assert.ok(winDomainApprovedDoc.parameters.ChangeDigest, 'WinDomain-ApprovedChange.yaml must define ChangeDigest parameter');

const invokeDeployScriptPath = path.join(root, 'scripts', 'Invoke-WuuDeployment.ps1');
assert.ok(fs.existsSync(invokeDeployScriptPath), 'Missing scripts/Invoke-WuuDeployment.ps1');

const getDeployStatusScriptPath = path.join(root, 'scripts', 'Get-DeploymentStatus.ps1');
assert.ok(fs.existsSync(getDeployStatusScriptPath), 'Missing scripts/Get-DeploymentStatus.ps1');

assert.ok(localStateContent.includes('Test-WuuNativeServicingActive'), 'Wuu.LocalState.psm1 must define Test-WuuNativeServicingActive');

const orchInfraPath = path.join(root, 'infra', 'orchestration.yaml');
assert.ok(fs.existsSync(orchInfraPath), 'Missing infra/orchestration.yaml');

const deployAslPath = path.join(root, 'cloud', 'deployment.asl.json');
assert.ok(fs.existsSync(deployAslPath), 'Missing cloud/deployment.asl.json');

const dispatchPath = path.join(root, 'cloud', 'dispatch.mjs');
assert.ok(fs.existsSync(dispatchPath), 'Missing cloud/dispatch.mjs');

const reconcilePath = path.join(root, 'cloud', 'reconcile.mjs');
assert.ok(fs.existsSync(reconcilePath), 'Missing cloud/reconcile.mjs');

const cancelPath = path.join(root, 'cloud', 'cancel.mjs');
assert.ok(fs.existsSync(cancelPath), 'Missing cloud/cancel.mjs');

const wuuRebootDocPath = path.join(root, 'documents', 'Wuu-Reboot.yaml');
assert.ok(fs.existsSync(wuuRebootDocPath), 'Missing documents/Wuu-Reboot.yaml');

const wuuRebootModPath = path.join(root, 'workers', 'Wuu.Reboot.psm1');
assert.ok(fs.existsSync(wuuRebootModPath), 'Missing workers/Wuu.Reboot.psm1');

const wuuVerifyDocPath = path.join(root, 'documents', 'Wuu-Verify.yaml');
assert.ok(fs.existsSync(wuuVerifyDocPath), 'Missing documents/Wuu-Verify.yaml');

const wuuPostcheckModPath = path.join(root, 'workers', 'Wuu.Postcheck.psm1');
assert.ok(fs.existsSync(wuuPostcheckModPath), 'Missing workers/Wuu.Postcheck.psm1');

const rebootRecoveryRunbookPath = path.join(root, 'runbooks', 'REBOOT-AND-PATCH-RECOVERY.md');
assert.ok(fs.existsSync(rebootRecoveryRunbookPath), 'Missing runbooks/REBOOT-AND-PATCH-RECOVERY.md');

const obsInfraPath = path.join(root, 'infra', 'observability.yaml');
assert.ok(fs.existsSync(obsInfraPath), 'Missing infra/observability.yaml');

const reportPath = path.join(root, 'cloud', 'report.mjs');
assert.ok(fs.existsSync(reportPath), 'Missing cloud/report.mjs');

const exportReportScriptPath = path.join(root, 'scripts', 'Export-DeploymentReport.ps1');
assert.ok(fs.existsSync(exportReportScriptPath), 'Missing scripts/Export-DeploymentReport.ps1');

const auditRunbookPath = path.join(root, 'runbooks', 'AUDIT-AND-RETENTION.md');
assert.ok(fs.existsSync(auditRunbookPath), 'Missing runbooks/AUDIT-AND-RETENTION.md');

const operationsRunbookPath = path.join(root, 'runbooks', 'OPERATIONS.md');
assert.ok(fs.existsSync(operationsRunbookPath), 'Missing runbooks/OPERATIONS.md');

const fixturesPath = path.join(root, 'tests', 'contracts', 'canonical-fixtures.json');
assert.ok(fs.existsSync(fixturesPath), 'Missing tests/contracts/canonical-fixtures.json');

const cloudPkgPath = path.join(root, 'cloud', 'package.json');
assert.ok(fs.existsSync(cloudPkgPath), 'Missing cloud/package.json');

const labQualPath = path.join(root, 'scripts', 'Invoke-LabQualification.ps1');
assert.ok(fs.existsSync(labQualPath), 'Missing scripts/Invoke-LabQualification.ps1');

const secQualPath = path.join(root, 'security', 'qualification.md');
assert.ok(fs.existsSync(secQualPath), 'Missing security/qualification.md');

const ghValidatePath = path.join(root, '.github', 'workflows', 'validate.yml');
assert.ok(fs.existsSync(ghValidatePath), 'Missing .github/workflows/validate.yml');

const ghDeployPath = path.join(root, '.github', 'workflows', 'deploy.yml');
assert.ok(fs.existsSync(ghDeployPath), 'Missing .github/workflows/deploy.yml');

const deployEnvScriptPath = path.join(root, 'scripts', 'Deploy-Environment.ps1');
assert.ok(fs.existsSync(deployEnvScriptPath), 'Missing scripts/Deploy-Environment.ps1');

const rollbackScriptPath = path.join(root, 'scripts', 'Rollback-Release.ps1');
assert.ok(fs.existsSync(rollbackScriptPath), 'Missing scripts/Rollback-Release.ps1');

const releaseRunbookPath = path.join(root, 'runbooks', 'RELEASE.md');
assert.ok(fs.existsSync(releaseRunbookPath), 'Missing runbooks/RELEASE.md');

const handoverRunbookPath = path.join(root, 'runbooks', 'HANDOVER.md');
assert.ok(fs.existsSync(handoverRunbookPath), 'Missing runbooks/HANDOVER.md');

process.stdout.write(JSON.stringify({
  requirementsCovered: specToPlanDoc.summary.covered_requirements,
  tasksTracked: planToTasksDoc.summary.total_tasks_generated,
  environmentTemplate: envExampleDoc.environment,
  networkTemplate: 'infra/network.yaml',
  plan12Artifacts: [
    'scripts/Test-NodeConnectivity.ps1',
    'runbooks/NETWORK.md',
    'documents/Wuu-Bootstrap.yaml',
    'documents/Wuu-Inventory.yaml',
    'schemas/node-inventory.schema.json'
  ],
  plan21Artifacts: [
    'infra/iam.yaml',
    'infra/secrets.yaml',
    'runbooks/SECRETS.md',
    'security/authorization-matrix.md',
    'scripts/Test-AwsAuthorization.ps1'
  ],
  plan22Artifacts: [
    'infra/storage.yaml',
    'schemas/release-manifest.schema.json',
    'scripts/Build-WorkerPackage.ps1',
    'scripts/Publish-Documents.ps1',
    'scripts/Publish-WorkerPackage.ps1',
    'workers/Wuu.Artifacts.psm1'
  ],
  plan23Artifacts: [
    'infra/state.yaml',
    'schemas/operation.schema.json',
    'cloud/state.mjs',
    'workers/Wuu.LocalState.psm1',
    'runbooks/RECOVERY.md'
  ],
  phase3Artifacts: [
    'workers/Wuu.LocalUpdate.psm1',
    'workers/Invoke-WuuWorker.ps1',
    'schemas/worker-result.schema.json',
    'workers/Wuu.Result.psm1',
    'documents/Wuu-Scan.yaml',
    'documents/Wuu-Download.yaml',
    'documents/Wuu-Install.yaml',
    'workers/Wuu.WsusPolicy.psm1',
    'schemas/update-selection.schema.json',
    'runbooks/WSUS-INTEGRATION.md'
  ],
  phase4Artifacts: [
    'schemas/change-plan.schema.json',
    'cloud/build-plan.mjs',
    'cloud/validate-plan.mjs',
    'documents/Wuu-ApprovedDeployment.yaml',
    'scripts/Invoke-WuuDeployment.ps1',
    'scripts/Get-DeploymentStatus.ps1'
  ],
  phase5Artifacts: [
    'infra/orchestration.yaml',
    'cloud/deployment.asl.json',
    'cloud/dispatch.mjs',
    'cloud/reconcile.mjs',
    'cloud/cancel.mjs',
    'documents/Wuu-Reboot.yaml',
    'workers/Wuu.Reboot.psm1',
    'documents/Wuu-Verify.yaml',
    'workers/Wuu.Postcheck.psm1',
    'runbooks/REBOOT-AND-PATCH-RECOVERY.md'
  ],
  phase6Artifacts: [
    'infra/observability.yaml',
    'cloud/report.mjs',
    'scripts/Export-DeploymentReport.ps1',
    'runbooks/AUDIT-AND-RETENTION.md',
    'runbooks/OPERATIONS.md'
  ],
  phase7Artifacts: [
    'tests/contracts/canonical-fixtures.json',
    'cloud/package.json',
    'scripts/Invoke-LabQualification.ps1',
    'security/qualification.md',
    '.github/workflows/validate.yml',
    '.github/workflows/deploy.yml',
    'scripts/Deploy-Environment.ps1',
    'scripts/Rollback-Release.ps1',
    'runbooks/RELEASE.md',
    'runbooks/HANDOVER.md'
  ]
}));

