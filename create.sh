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

echo "Setting up GitOps polling (CronJob)..."
oc apply -f triggers/cronjob-poll.yaml -n "${NAMESPACE}"

echo ""
echo "Infrastructure deployed. Application builds will be triggered automatically"
echo "by the CronJob polling the source repository every 5 minutes."
echo ""
echo "To trigger a manual build:"
echo "  tkn pipeline start build -p app-name=correlator -p app-path=smart-log-analyzer/correlator -p gav=com.example:correlator:1.0.0 -p runtime=${RUNTIME} -w name=shared-workspace,volumeClaimTemplateFile=pipelinerun/build-run.yaml"
