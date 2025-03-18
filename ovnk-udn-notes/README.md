# Observations running Sail Operator in a UDN network on OCP 4.18 cluster

1. Let's create the necessary namespaces for Sail Operator and Istio components.

```shell
#!/bin/bash

namespaces_without_injection=("istio-system" "istio-cni" "sail-operator")

for ns in "${namespaces_without_injection[@]}"; do
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
EOF
done
```

2. Create the `sample` and `httpbin` namespaces with the required labels.

```shell
#!/bin/bash

namespaces_with_injection=("sleep" "httpbin")

for ns in "${namespaces_with_injection[@]}"; do
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
    istio-injection: "enabled"
EOF
done
```

3. Create a Primary `ClusterUserDefinedNetwork` CR named `istio-cudn`

```shell
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: istio-cudn
spec:                                                                                                                                                                                         
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values: ["sleep", "httpbin", "istio-system", "istio-cni", "sail-operator"]
  network:
    topology: Layer3
    layer3:
      role: Primary
      subnets:
        - cidr: 10.100.0.0/16
          hostSubnet: 24
EOF          
```

4. Clone the Sail Operator repo and install it on the OCP cluster.

```shell
git clone https://github.com/istio-ecosystem/sail-operator.git
cd sail-operator
make deploy
```

5. Wait for the sail-operator to be installed. Once its up and running, let's install Istio.

```shell
make deploy-istio-with-cni
```

6. Deploy `sleep` and `httpbin` pods in their respective namespaces.

```shell
oc apply -n sleep -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml
oc apply -n httpbin -f https://raw.githubusercontent.com/sridhargaddam/istio-workspace/refs/heads/main/sample-yamls-ambient/httpbin.yaml
```

7. You'll notice that both `sleep` and `httpbin` pods fail to come up as the webhook cannot reach the istiod service.

```shell
oc get deployment httpbin -n httpbin -oyaml
<SNIP>
status:
  conditions:
  - lastTransitionTime: "2025-03-18T12:54:20Z"
    lastUpdateTime: "2025-03-18T12:54:20Z"
    message: Deployment does not have minimum availability.
    reason: MinimumReplicasUnavailable
    status: "False"
    type: Available
  - lastTransitionTime: "2025-03-18T12:54:30Z"
    lastUpdateTime: "2025-03-18T12:54:30Z"
    message: 'Internal error occurred: failed calling webhook "namespace.sidecar-injector.istio.io":
      failed to call webhook: Post "https://istiod.istio-system.svc:443/inject?timeout=10s":
      dial tcp 10.128.2.121:15017: i/o timeout'
    reason: FailedCreate
    status: "True"
    type: ReplicaFailure
  - lastTransitionTime: "2025-03-18T13:04:21Z"
    lastUpdateTime: "2025-03-18T13:04:21Z"
    message: ReplicaSet "httpbin-67b6484f8d" has timed out progressing.
    reason: ProgressDeadlineExceeded
    status: "False"
    type: Progressing
  observedGeneration: 1
  unavailableReplicas: 1
```
