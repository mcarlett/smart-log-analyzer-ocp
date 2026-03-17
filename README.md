# Smart Log Analyzer OCP

Tekton pipelines for deploying infrastructure and building Apache Camel JBang applications on OpenShift. The `infra-deploy` pipeline installs the required operators and deploys AMQ Broker, Infinispan (Data Grid) with pre-configured caches, and HashiCorp Vault for secrets management. The `build-and-deploy` pipeline exports a Camel application to a Quarkus project, builds it with Maven, creates a container image with Buildah, and deploys it.

## Project Structure

```
smart-log-analyzer-ocp/
├── tasks/
│   ├── 00-install-operator.yaml        # Reusable task to install any OLM operator
│   ├── 01-deploy-amq-broker.yaml      # Deploys an ActiveMQArtemis instance
│   ├── 02-deploy-infinispan.yaml      # Deploys an Infinispan cluster with caches
│   ├── 03-create-infra-endpoints.yaml # Creates infra-endpoints ConfigMap with service URLs
│   ├── 04-generate-vault-token.yaml  # Generates a random Vault root token
│   ├── 05-configure-vault.yaml      # Waits for Vault pod and stores infra-accounts secrets
│   ├── 10-init-workspace.yaml         # Fixes PVC permissions for workspace
│   ├── 11-camel-export.yaml           # Runs camel export to Quarkus
│   └── 12-prepare-dockerfile.yaml     # Writes Dockerfile from base-image-config ConfigMap to workspace
│
├── pipeline/
│   ├── build-and-deploy.yaml      # Pipeline orchestrating build tasks
│   └── infra-deploy.yaml          # Pipeline to install operators and deploy AMQ Broker, Infinispan + Vault
│
├── pipelinerun/
│   ├── build-and-deploy-run.yaml  # Example PipelineRun for the correlator component
│   └── infra-deploy-run.yaml      # Example PipelineRun for operator installation
│
└── resources/
    ├── amq-broker/
    │   └── artemis.yaml                     # ActiveMQArtemis CR definition
    ├── infinispan/
    │   ├── infinispan.yaml                  # Infinispan CR definition
    │   └── caches/
    │       ├── events.json                  # Cache config for 'events' (600s lifespan)
    │       └── events-to-process.json       # Cache config for 'events-to-process' (20s lifespan)
    ├── rbac/
    │   ├── pipeline-clusterrole.yaml        # Scoped ClusterRole for the pipeline SA
    │   └── pipeline-clusterrolebinding.yaml  # Binds the ClusterRole to the pipeline SA
    ├── app-config/
    │   ├── correlator/
    │   │   └── application-prod.properties  # Production config (Vault refs for credentials)
    │   ├── analyzer/
    │   │   └── application-prod.properties  # Production config (Vault refs for credentials)
    │   ├── ui-console/
    │   │   └── application-prod.properties  # Production config (Vault refs for credentials)
    │   └── log-generator/
    │       └── application-prod.properties  # Production config (OpenTelemetry)
    ├── vault/
    │   └── sa-hashicorp-vault.yaml          # ServiceAccount for application access to Vault
    ├── configmaps/
    │   └── base-image-config.yaml           # Dockerfile for building the application image
    └── secrets/
        └── infra-accounts.yaml              # Infrastructure credentials (AMQ Broker, Data Grid)
```

## Pipeline Execution Order

### infra-deploy

```
                              → generate-vault-token → install-vault → configure-vault         ↘
init-workspace → git-clone → create-operator-group → install-datagrid    → deploy-infinispan  → create-infra-endpoints
                                                    → install-amq-broker → deploy-amq-broker  ↗
```

| Task | Source | Description |
|---|---|---|
| **init-workspace** | Custom | Fixes PVC permissions |
| **git-clone** | `openshift-pipelines` | Clones this repository to access resource files |
| **create-operator-group** | `openshift-pipelines` | Creates the OperatorGroup for the namespace |
| **install-operator** | Custom | Installs an OLM operator via Subscription, waits for CSV to succeed |
| **deploy-amq-broker** | Custom | Applies `resources/amq-broker/artemis.yaml`, waits for pod ready |
| **deploy-infinispan** | Custom | Applies `resources/infinispan/infinispan.yaml`, creates caches from `resources/infinispan/caches/*.json` |
| **generate-vault-token** | Custom | Generates a random UUID-based root token for Vault |
| **install-vault** | `openshift-pipelines` | Installs the Vault Helm chart from repo using `helm-upgrade-from-repo` (dev mode, random root token) |
| **configure-vault** | Custom | Waits for Vault pod to be ready, writes all `infra-accounts` secrets to `secret/<key>`, creates `sa-hashicorp-vault` service account with Kubernetes auth |
| **create-infra-endpoints** | Custom | Creates `infra-endpoints` ConfigMap with AMQ Broker, Infinispan, and Vault service URLs |

### build-and-deploy

```
init-workspace → git-clone → fix-workspace → camel-export → maven (package) → prepare-dockerfile → buildah (build image) → deploy
```

| Task | Source | Description |
|---|---|---|
| **init-workspace** | Custom | Fixes PVC permissions |
| **git-clone** | `openshift-pipelines` | Clones the source repository |
| **fix-workspace** | Custom | Fixes permissions after git-clone for subsequent tasks |
| **camel-export** | Custom | Runs `camel export --runtime=quarkus` to produce a Maven project |
| **maven** | `openshift-pipelines` | Runs `./mvnw clean package` to build the Quarkus application |
| **prepare-dockerfile** | Custom | Writes Dockerfile from `base-image-config` ConfigMap to workspace |
| **buildah** | `openshift-pipelines` | Builds the container image from `src/main/docker/Dockerfile.jvm` |
| **openshift-client** | `openshift-pipelines` | Creates or updates the Deployment |

## Prerequisites

- OpenShift 4 cluster
- Red Hat OpenShift Pipelines operator installed
- Tekton CLI (`tkn`) (optional, for monitoring runs)

## Usage

### Deploy the pipeline

```bash
# Create the target namespace
oc new-project slog-analyzer

# Apply RBAC, secrets, configmaps, tasks, and pipelines
oc apply -f resources/rbac/
oc apply -f resources/secrets/
oc apply -f resources/configmaps/
oc apply -f tasks/
oc apply -f pipeline/

# Install operators and deploy AMQ Broker, Infinispan + Vault
oc create -f pipelinerun/infra-deploy-run.yaml

# Wait for infra-deploy to complete, then build and deploy the application
oc create -f pipelinerun/build-and-deploy-run.yaml
```

### Monitor the run

```bash
# Follow logs of the latest run
tkn pipelinerun logs -f -L

# List pipeline runs
tkn pipelinerun list
```

### Build a different component

The pipeline is parametrizable. To build a different component of the smart-log-analyzer (e.g. `analyzer`, `ui-console`):

```bash
tkn pipeline start build-and-deploy \
  -p app-path=smart-log-analyzer/analyzer \
  -p app-name=analyzer \
  -p gav=com.example:analyzer:1.0.0 \
  -w name=shared-workspace,volumeClaimTemplateFile=pipelinerun/build-and-deploy-run.yaml
```

## Configuration

### build-and-deploy parameters

| Parameter | Default | Description |
|---|---|---|
| `repo-url` | `https://github.com/apache/camel-jbang-examples.git` | Git repository URL |
| `repo-revision` | `main` | Git branch, tag, or commit SHA |
| `app-path` | `smart-log-analyzer/correlator` | Path within the repo to the Camel app |
| `app-name` | `correlator` | Application name (image and deployment name) |
| `namespace` | `slog-analyzer` | Target namespace |
| `camel-image` | `quay.io/mcarlett/camel-launcher:4.18.0` | Image with the Camel CLI (configurable) |
| `gav` | `com.example:correlator:1.0.0` | Maven groupId:artifactId:version |

### infra-deploy parameters

| Parameter | Default | Description |
|---|---|---|
| `namespace` | `slog-analyzer` | Target namespace for operator and CR deployment |
| `repo-url` | `https://github.com/mcarlett/smart-log-analyzer-ocp.git` | Git repository URL containing resource files |
| `repo-revision` | `main` | Git revision (branch, tag, or commit SHA) |

### Infrastructure endpoints

The `infra-endpoints` ConfigMap is created automatically by the `infra-deploy` pipeline and contains:

| Key | Example value | Description |
|---|---|---|
| `ARTEMIS_BROKER_URL` | `tcp://artemis-0-svc.slog-analyzer.svc:61616` | AMQ Broker core protocol URL (for JMS/ActiveMQ clients) |
| `INFINISPAN_HOSTS` | `infinispan.slog-analyzer.svc:11222` | Infinispan host:port (for Camel Infinispan component) |
| `HASHICORP_HOST` | `vault.slog-analyzer.svc` | Vault host (for Camel HashiCorp Vault component) |
| `HASHICORP_PORT` | `8200` | Vault port (for Camel HashiCorp Vault component) |

### Vault

The Vault deployment tasks (`generate-vault-token`, `install-vault`, `configure-vault`) automatically:
1. Generates a random root token (UUID-based)
2. Installs Vault via the [HashiCorp Helm chart](https://github.com/hashicorp/vault-helm) in dev mode (`server.dev.enabled=true`) with the generated token
3. Dev mode enables a KV v2 secrets engine at `secret/`
4. Writes all keys from the `infra-accounts` secret into Vault (e.g. `secret/amq-username`, `secret/datagrid-password`)
5. Creates a `sa-hashicorp-vault` ServiceAccount and configures Vault Kubernetes auth (enables auth method, creates a read-only policy on `secret/data/*`, and binds the role to the service account)
6. Creates a `vault-token` Secret containing the `HASHICORP_TOKEN` for application use

### Infrastructure credentials

The `infra-accounts` secret is defined in `resources/secrets/infra-accounts.yaml` and contains the following keys:

| Key | Default | Description |
|---|---|---|
| `amq-username` | `artemis` | AMQ Broker admin username |
| `amq-password` | `artemis` | AMQ Broker admin password |
| `datagrid-username` | `admin` | Infinispan/Data Grid admin username |
| `datagrid-password` | `password` | Infinispan/Data Grid admin password |

## Cleanup

```bash
# Delete the Infinispan and AMQ Broker CRs first (allows operators to clean up)
oc delete infinispan infinispan -n slog-analyzer
oc delete activemqartemis artemis -n slog-analyzer

# Uninstall Vault Helm release
helm uninstall vault -n slog-analyzer

# Delete all task runs and tasks
oc delete taskrun --all -n slog-analyzer
oc delete task --all -n slog-analyzer

# Delete all pipeline runs and pipelines
oc delete pipelinerun --all -n slog-analyzer
oc delete pipeline --all -n slog-analyzer

# Delete the namespace and all remaining resources
oc delete project slog-analyzer

# Remove cluster-scoped RBAC resources
oc delete clusterrolebinding slog-analyzer-pipeline
oc delete clusterrole slog-analyzer-pipeline
```
