#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [NAMESPACE] [RUNTIME] [KAFKA_NAMESPACE]

Deploy the Smart Log Analyzer infrastructure and applications on OpenShift.

Arguments:
  NAMESPACE        Target namespace (default: slog-analyzer)
  RUNTIME          Camel runtime: quarkus or spring-boot (default: quarkus)
  KAFKA_NAMESPACE  Namespace containing the Strimzi Kafka cluster CA secret (default: camel-otel-infra)

Examples:
  $(basename "$0")                                      # defaults: slog-analyzer, quarkus, camel-otel-infra
  $(basename "$0") my-ns spring-boot                    # Spring Boot runtime in my-ns namespace
  $(basename "$0") my-ns quarkus my-kafka-ns            # custom Kafka namespace
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

NAMESPACE="${1:-slog-analyzer}"
RUNTIME="${2:-quarkus}"
KAFKA_NAMESPACE="${3:-camel-otel-infra}"

echo "Creating project ${NAMESPACE}..."
oc new-project "${NAMESPACE}" || oc project "${NAMESPACE}"

echo "Applying RBAC, secrets, configmaps, PVCs, tasks, and pipelines..."
oc apply -f resources/rbac/
oc apply -f resources/secrets/
oc apply -f resources/configmaps/
oc apply -f resources/pvc/
oc apply -f tasks/
oc apply -f pipeline/

echo "Starting infra-deploy pipeline..."
oc create -f pipelinerun/infra-deploy-run.yaml

echo "Waiting for infra-deploy to complete..."
tkn pipelinerun logs -f -L

echo "Creating kafka-cluster-ca secret..."
oc get secret camel-cluster-cluster-ca-cert -n "${KAFKA_NAMESPACE}" -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
oc create secret generic kafka-cluster-ca --from-file=ca.crt=/tmp/ca.crt -n "${NAMESPACE}"

echo "Deploying all components with ${RUNTIME} runtime..."
oc create -f "pipelinerun/deploy-smart-log-analyzer-${RUNTIME}-run.yaml"

echo "Following deploy logs..."
tkn pipelinerun logs -f -L
