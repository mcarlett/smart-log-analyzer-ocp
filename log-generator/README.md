# Log Generator

Builds and deploys the [log-generator](https://github.com/apache/camel-jbang-examples/tree/main/smart-log-analyzer/log-generator) Camel application. This app simulates order processing with random failures to generate realistic log data for testing the Smart Log Analyzer.

The image is built with the OpenTelemetry Java agent bundled in, so no external operator or `Instrumentation` CR is needed.

## Setup

```bash
# Apply the pipeline
oc apply -f log-generator/pipeline.yaml

# Run the pipeline
oc create -f log-generator/pipelinerun.yaml
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `repo-url` | `https://github.com/apache/camel-jbang-examples.git` | Git repository URL |
| `repo-revision` | `main` | Git revision (branch, tag, or commit SHA) |
| `namespace` | `slog-analyzer` | Target namespace for the image and deployment |
| `otel-collector-endpoint` | `http://camel-otel-collector-opentelemetry-collector.slog-analyzer.svc:4317` | OTLP collector endpoint |
