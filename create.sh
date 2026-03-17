#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-slog-analyzer}"

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

echo "Starting build-and-deploy pipeline..."
oc create -f pipelinerun/build-and-deploy-run.yaml

echo "Following build-and-deploy logs..."
tkn pipelinerun logs -f -L
