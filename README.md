# Smart Log Analyzer OCP

Tekton pipelines for deploying infrastructure and building Apache Camel JBang applications on OpenShift. The `infra-deploy` pipeline installs the required operators and deploys AMQ Broker, Infinispan (Data Grid) with pre-configured caches, and HashiCorp Vault for secrets management. The `build-and-deploy` pipeline exports a Camel application to a target runtime (Quarkus or Spring Boot), builds it with Maven, creates a container image with Buildah, and deploys it.

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
│   ├── 11-camel-export.yaml           # Runs camel export to target runtime (quarkus or spring-boot)
│   ├── 12-add-quarkus-extension.yaml  # Adds Quarkus extensions to the exported project
│   ├── 13-prepare-dockerfile.yaml     # Writes Dockerfile from base-image-config ConfigMap to workspace
│   └── 14-create-app-config.yaml      # Creates app-config ConfigMap from resolved properties file
│
├── pipeline/
│   ├── build-and-deploy.yaml           # Pipeline orchestrating build tasks for a single component
│   ├── deploy-smart-log-analyzer.yaml  # Pipeline that deploys all components (correlator, analyzer, ui-console) in parallel
│   └── infra-deploy.yaml               # Pipeline to install operators and deploy AMQ Broker, Infinispan + Vault
│
├── pipelinerun/
│   ├── build-and-deploy-run.yaml           # Example PipelineRun for the correlator component
│   ├── deploy-smart-log-analyzer-quarkus-run.yaml      # PipelineRun to deploy all components with Quarkus runtime
│   ├── deploy-smart-log-analyzer-spring-boot-run.yaml  # PipelineRun to deploy all components with Spring Boot runtime
│   └── infra-deploy-run.yaml               # Example PipelineRun for operator installation
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
    │   │   ├── application-prod-quarkus.properties      # Production config for Quarkus runtime
    │   │   └── application-prod-spring-boot.properties  # Production config for Spring Boot runtime
    │   ├── analyzer/
    │   │   ├── application-prod-quarkus.properties      # Production config for Quarkus runtime
    │   │   └── application-prod-spring-boot.properties  # Production config for Spring Boot runtime
    │   ├── ui-console/
    │   │   ├── application-prod-quarkus.properties      # Production config for Quarkus runtime
    │   │   └── application-prod-spring-boot.properties  # Production config for Spring Boot runtime
    │   └── log-generator/
    │       ├── application-prod-quarkus.properties      # Production config for Quarkus runtime
    │       └── application-prod-spring-boot.properties  # Production config for Spring Boot runtime
    ├── vault/
    │   └── sa-hashicorp-vault.yaml          # ServiceAccount for application access to Vault
    ├── pvc/
    │   └── maven-repo.yaml                  # PVC for persistent Maven repository cache (1Gi)
    ├── configmaps/
    │   ├── base-image-config-quarkus.yaml       # Dockerfile for Quarkus fast-jar image layout
    │   ├── base-image-config-spring-boot.yaml   # Dockerfile for Spring Boot fat-jar image layout
    │   └── otel-infra-endpoints.yaml            # Endpoints for the existing OpenTelemetry infrastructure
    ├── secrets/
    │   └── infra-accounts.yaml              # Infrastructure credentials (AMQ Broker, Data Grid)
    └── templates/
        └── kafka-cluster-ca.yaml            # Template for Kafka cluster CA certificate (must be populated and applied manually)
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
                 → git-clone        ↘                → create-app-config
init-workspace →                     fix-workspace →                      → camel-export → add-quarkus-extension (if quarkus) → fix-export-permissions → maven-build → prepare-dockerfile → buildah (build image) → deploy
                 → git-clone-config ↗
```

| Task | Source | Description |
|---|---|---|
| **init-workspace** | Custom | Fixes PVC permissions |
| **git-clone** | `openshift-pipelines` | Clones the source repository |
| **git-clone-config** | `openshift-pipelines` | Clones the config repository (containing `resources/app-config/`) |
| **fix-workspace** | Custom | Fixes permissions after git-clone for subsequent tasks |
| **create-app-config** | Custom | Resolves properties file (`application-prod-<runtime>.properties` > `application-prod.properties` > `application-dev.properties` > `application.properties`) and creates a `<app-name>-config` ConfigMap, mounted at `/deployments/config/application.properties` in the deployment |
| **camel-export** | Custom | Runs `camel export --runtime=<runtime>` to generate a Quarkus or Spring Boot project, with optional `--dep` for additional dependencies |
| **add-quarkus-extension** | Custom | Adds Quarkus extensions (e.g. `camel-quarkus-hashicorp-vault`) to the exported project (skipped for spring-boot runtime) |
| **fix-export-permissions** | Inline | Fixes workspace permissions after export/extensions (always runs regardless of runtime) |
| **maven-build** | Inline | Runs `./mvnw clean package` using `ubi9/openjdk-21` to build the application |
| **prepare-dockerfile** | Custom | Writes Dockerfile from `base-image-config-<runtime>` ConfigMap to workspace (Quarkus fast-jar or Spring Boot fat-jar layout) |
| **buildah** | `openshift-pipelines` | Builds the container image from `src/main/docker/Dockerfile.jvm` |
| **openshift-client** | `openshift-pipelines` | Creates the Deployment with 0 replicas, applies all configuration (env vars from `infra-endpoints`, `otel-infra-endpoints` ConfigMaps, `vault-token` Secret, memory limit 2Gi, volumes, optional storage PVC, extra env vars, optional Route). For Quarkus: injects `infra-accounts` credentials as env vars and sets Netty native transport workaround. Then scales to the desired replica count |

### deploy-smart-log-analyzer

```
                          → deploy-correlator  (build-and-deploy with extensions: hashicorp-vault)
check-prerequisites  →    → deploy-analyzer    (build-and-deploy with extensions: hashicorp-vault)
                          → deploy-ui-console  (build-and-deploy with extensions: hashicorp-vault, platform-http)
```

| Task | Source | Description |
|---|---|---|
| **check-prerequisites** | `openshift-pipelines` | Validates that the `kafka-cluster-ca` secret exists before proceeding |
| **deploy-correlator** | `openshift-pipelines` | Triggers a `build-and-deploy` PipelineRun for the correlator component and waits for completion |
| **deploy-analyzer** | `openshift-pipelines` | Triggers a `build-and-deploy` PipelineRun for the analyzer component and waits for completion |
| **deploy-ui-console** | `openshift-pipelines` | Triggers a `build-and-deploy` PipelineRun for the ui-console component (with `camel-quarkus-platform-http`, persistent storage at `/storage`, `ANALYZER_STORAGE_ROOT=/storage`, `expose=true`) and waits for completion. The created Route allows external access to the UI |

## Prerequisites

- OpenShift 4 cluster
- Red Hat OpenShift Pipelines operator installed
- Tekton CLI (`tkn`) (optional, for monitoring runs)
- Kafka cluster CA certificate: populate `resources/secrets/kafka-cluster-ca.yaml` with the CA certificate (PEM format) of the external Kafka cluster used for OpenTelemetry data

## Usage

### Deploy the pipeline

```bash
# Create the target namespace
oc new-project slog-analyzer

# Apply RBAC, secrets, configmaps, tasks, and pipelines
oc apply -f resources/rbac/
oc apply -f resources/secrets/
oc apply -f resources/configmaps/
oc apply -f resources/pvc/
oc apply -f tasks/
oc apply -f pipeline/

# Install operators and deploy AMQ Broker, Infinispan + Vault
oc create -f pipelinerun/infra-deploy-run.yaml

# Create the kafka-cluster-ca secret (see Kafka TLS section below)

# Wait for infra-deploy to complete, then deploy all components (choose runtime)
oc create -f pipelinerun/deploy-smart-log-analyzer-quarkus-run.yaml
# or
oc create -f pipelinerun/deploy-smart-log-analyzer-spring-boot-run.yaml
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
| `config-repo-url` | `https://github.com/mcarlett/smart-log-analyzer-ocp.git` | Git repository URL containing app-config |
| `config-repo-revision` | `main` | Git revision for the config repository |
| `runtime` | `quarkus` | Target runtime for the camel export: `quarkus` or `spring-boot` |
| `runtime-version` | _(empty)_ | Runtime platform version (Quarkus or Spring Boot). If empty, uses the default from camel export |
| `extensions` | `org.apache.camel.quarkus:camel-quarkus-hashicorp-vault` | Comma-separated list of Quarkus extensions to add (only used with quarkus runtime) |
| `deps` | _(empty)_ | Comma-separated list of additional dependencies to add during `camel export` via `--dep` (e.g. `org.apache.camel.springboot:camel-hashicorp-vault-starter` for Spring Boot) |
| `storage-mount-point` | _(empty)_ | If set, creates a `<app-name>-storage` PVC and mounts it at this path |
| `storage-size` | `1Gi` | Size of the persistent storage PVC (only used if `storage-mount-point` is set) |
| `extra-env` | _(empty)_ | Comma-separated `key=value` pairs for extra environment variables |
| `replicas` | `1` | Number of replicas for the deployment |
| `expose` | `false` | If `true`, creates a Service and Route to expose the deployment externally |

### deploy-smart-log-analyzer parameters

| Parameter | Default | Description |
|---|---|---|
| `repo-url` | `https://github.com/apache/camel-jbang-examples.git` | Git repository URL |
| `repo-revision` | `main` | Git branch, tag, or commit SHA |
| `namespace` | `slog-analyzer` | Target namespace |
| `camel-image` | `quay.io/mcarlett/camel-launcher:4.18.0` | Image with the Camel CLI |
| `config-repo-url` | `https://github.com/mcarlett/smart-log-analyzer-ocp.git` | Git repository URL containing app-config |
| `config-repo-revision` | `main` | Git revision for the config repository |
| `runtime` | `quarkus` | Target runtime: `quarkus` or `spring-boot` |
| `runtime-version` | _(empty)_ | Runtime platform version. If empty, uses the default from camel export |

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
| `ARTEMIS_BROKER_URL` | `tcp://artemis-hdls-svc.slog-analyzer.svc:61616` | AMQ Broker headless service URL (for JMS/ActiveMQ clients) |
| `INFINISPAN_HOSTS` | `infinispan.slog-analyzer.svc:11222` | Infinispan host:port (for Camel Infinispan component) |
| `HASHICORP_HOST` | `vault.slog-analyzer.svc` | Vault host (for Camel HashiCorp Vault component) |
| `HASHICORP_PORT` | `8200` | Vault port (for Camel HashiCorp Vault component) |

### OpenTelemetry infrastructure endpoints

The `otel-infra-endpoints` ConfigMap (defined in `resources/configmaps/otel-infra-endpoints.yaml`) contains the connection details for the existing OpenTelemetry infrastructure, which is the source of traces and logs to analyze:

| Key | Default | Description |
|---|---|---|
| `KAFKA_BROKERS` | `camel-cluster-kafka-bootstrap.camel-otel-infra.svc.cluster.local:9093` | Kafka bootstrap server where OpenTelemetry traces and logs are published |

### Vault

The Vault deployment tasks (`generate-vault-token`, `install-vault`, `configure-vault`) automatically:
1. Generates a random root token (UUID-based)
2. Installs Vault via the [HashiCorp Helm chart](https://github.com/hashicorp/vault-helm) in dev mode (`server.dev.enabled=true`) with the generated token
3. Dev mode enables a KV v2 secrets engine at `secret/`
4. Writes all keys from the `infra-accounts` secret into Vault (e.g. `secret/amq-username`, `secret/datagrid-password`)
5. Creates a `sa-hashicorp-vault` ServiceAccount and configures Vault Kubernetes auth (enables auth method, creates a read-only policy on `secret/data/*`, and binds the role to the service account)
6. Creates a `vault-token` Secret containing the `HASHICORP_TOKEN` for application use

### Maven repository cache

The `build-and-deploy` pipeline uses a persistent `maven-repo` PVC (1Gi, defined in `resources/pvc/maven-repo.yaml`) to cache Maven dependencies across pipeline runs. The PVC is mounted via `subPath: m2-settings` on the `shared-workspace` to both the `add-quarkus-extension` and `maven-build` steps, avoiding repeated downloads and speeding up subsequent builds.

### Kafka TLS

The Kafka cluster (Strimzi) uses TLS on port 9093. The `kafka-cluster-ca` secret must contain the cluster CA certificate used to verify the Kafka broker's identity. The deploy task mounts this secret at `/etc/kafka-ca` in the application pod, and the correlator is configured to use `/etc/kafka-ca/ca.crt` as the SSL truststore.

To populate the secret, copy the CA certificate from the Kafka cluster namespace:

```bash
# Extract the CA cert from the Strimzi cluster (adjust namespace and cluster name as needed)
oc get secret camel-cluster-cluster-ca-cert -n camel-otel-infra -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt

# Create the secret in the target namespace
oc create secret generic kafka-cluster-ca --from-file=ca.crt=/tmp/ca.crt -n slog-analyzer
```

Alternatively, edit the template at `resources/templates/kafka-cluster-ca.yaml` with the PEM-encoded CA certificate and apply it manually with `oc apply -f resources/templates/kafka-cluster-ca.yaml`.

### Runtime differences

The pipeline supports both **Quarkus** and **Spring Boot** runtimes. Key differences in the application configuration:

| Feature | Quarkus | Spring Boot |
|---|---|---|
| JMS connection | `camel.beans.*` (Camel bean DSL) | `spring.artemis.*` (Spring Boot auto-configuration) |
| HTTP server | `camel-quarkus-platform-http` | `server.port` / `camel.rest.component=platform-http` |
| Vault placeholders | `{{hashicorp:secret:key}}` | `{{hashicorp:secret:key#value}}` with `camel.component.hashicorp-vault.early-resolve-properties=true` |
| Vault dependency | `camel-quarkus-hashicorp-vault` (Quarkus extension) | `camel-hashicorp-vault-starter` (added via `--dep` during export) |
| Infinispan credentials | Env vars from `infra-accounts` secret (Quarkus extension can't resolve vault placeholders) | Vault placeholders with `#value` field syntax |
| Netty workaround | `JAVA_OPTS_APPEND=-Dio.netty.transport.noNative=true` | Not needed |
| Container image | Fast-jar layout (`quarkus-app/`) | Fat jar (`app.jar`) |

Both runtimes use `camel.main.name` for the application name. Runtime-specific properties files are stored in `resources/app-config/<component>/application-prod-<runtime>.properties`.

Vault KV v2 stores secrets as JSON objects (e.g. `{"value": "artemis"}`). The `#value` field selector extracts the specific field: `{{hashicorp:secret:amq-username#value}}` resolves to `artemis`. See the [Camel HashiCorp Vault documentation](https://camel.apache.org/components/4.18.x/hashicorp-vault-component.html) for the full placeholder syntax.

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
