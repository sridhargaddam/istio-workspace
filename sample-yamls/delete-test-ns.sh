#!/bin/sh

# This script delete the test namespaces created while running Istio integration tests
kubectl get ns -l istio-testing=istio-test -o jsonpath='{.items[*].metadata.name}' | xargs kubectl delete ns
