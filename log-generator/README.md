# Log Generator

Deploys the [log-generator](https://github.com/mcarlett/camel-jbang-examples/tree/tekton/smart-log-analyzer/log-generator) Camel application in a dedicated `log-generator` namespace. This app simulates order processing with random failures to generate realistic log data for testing the Smart Log Analyzer.

## Prerequisites

1. OpenTelemetry Operator installed on the cluster
2. Create the `Instrumentation` CR (update the `exporter.endpoint` to match your OTLP collector):

```bash
# Edit log-generator/instrumentation.yaml to set the correct endpoint, then apply
oc apply -f log-generator/instrumentation.yaml
```

## Setup

```bash
NS=log-generator

# Create the namespace (or use an existing one)
oc new-project $NS

# Apply the Instrumentation CR (edit the endpoint first if needed)
oc apply -f log-generator/instrumentation.yaml -n $NS

# Create the pipeline
oc apply -f log-generator/pipeline.yaml -n $NS

# Run the pipeline
oc create -f log-generator/pipelinerun.yaml -n $NS
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `namespace` | `log-generator` | Target namespace for deployment |
| `repo-url` | `https://github.com/mcarlett/camel-jbang-examples.git` | Git repository URL |
| `repo-branch` | `tekton` | Git branch |
| `app-path` | `smart-log-analyzer/log-generator` | Path to the app within the repo |
| `image` | `quay.io/mcarlett/camel-launcher:4.18.0` | Base image for running `camel run` |
