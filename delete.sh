#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-slog-analyzer}"

echo "Deleting Infinispan and AMQ Broker CRs..."
oc delete infinispan infinispan -n "${NAMESPACE}" --ignore-not-found
oc delete activemqartemis artemis -n "${NAMESPACE}" --ignore-not-found

echo "Uninstalling Vault Helm release..."
helm uninstall vault -n "${NAMESPACE}" || true

echo "Deleting task runs and tasks..."
oc delete taskrun --all -n "${NAMESPACE}"
oc delete task --all -n "${NAMESPACE}"

echo "Deleting pipeline runs and pipelines..."
oc delete pipelinerun --all -n "${NAMESPACE}"
oc delete pipeline --all -n "${NAMESPACE}"

echo "Deleting namespace ${NAMESPACE}..."
oc delete project "${NAMESPACE}"

echo "Removing cluster-scoped RBAC resources..."
oc delete clusterrolebinding "${NAMESPACE}-pipeline" --ignore-not-found
oc delete clusterrole "${NAMESPACE}-pipeline" --ignore-not-found

echo "Cleanup complete."
