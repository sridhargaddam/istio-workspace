# Sample commands to validate Istio Ambient mode using Sail Operator.

```shell
kind create cluster
```

Build a docker image of the Sail Operator.
```shell
# From the directory where the sail-operator repo is cloned.
IMAGE=quay.io/sridhargaddam/sail-operator:latest make docker-build
IMAGE=quay.io/sridhargaddam/sail-operator:latest make docker-push
```

Deploy the Sail Operator in the Kind cluster.
```shell
IMAGE=quay.io/sridhargaddam/sail-operator:latest make deploy
```

Create necessary namespaces and the associated CRs for Ambient support.
```shell
kubectl create ns istio-system || true
kubectl create ns istio-cni || true
kubectl create ns ztunnel || true
kubectl apply -f chart/samples/ambient/istio-sample.yaml
kubectl apply -f chart/samples/ambient/istiocni-sample.yaml
kubectl apply -f chart/samples/ambient/istioztunnel-sample.yaml
# Alternately, you can simply run "make deploy-istio-with-ambient"
```

Create a sample `curl` pod in the sleep namespace.
```shell
kubectl create namespace sleep || true
kubectl label namespace sleep istio.io/dataplane-mode=ambient --overwrite
kubectl apply -f https://raw.githubusercontent.com/sridhargaddam/istio-workspace/refs/heads/main/sample-yamls-ambient/sleep.yaml -n sleep
```

Create an `httpbin` pod in the httpbin namespace.
```shell
kubectl create namespace httpbin || true
kubectl label namespace httpbin istio.io/dataplane-mode=ambient --overwrite
kubectl apply -f https://raw.githubusercontent.com/sridhargaddam/istio-workspace/refs/heads/main/sample-yamls-ambient/httpbin.yaml -n httpbin
```

Verify that we are able to access the httpbin service from the sleep pod.
```shell
kubectl exec -it -n sleep deploy/sleep -- curl -s httpbin.httpbin.svc.cluster.local:8000/get
```

To confirm that `ztunnel` successfully opened listening sockets inside the pod network ns, use the following command.
```console
$: k exec -it -n sleep deploy/sleep -- netstat -tulpn
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 127.0.0.1:15053         0.0.0.0:*               LISTEN      -
tcp        0      0 ::1:15053               :::*                    LISTEN      -
tcp        0      0 :::15008                :::*                    LISTEN      -
tcp        0      0 :::15001                :::*                    LISTEN      -
tcp        0      0 :::15006                :::*                    LISTEN      -
udp        0      0 127.0.0.1:15053         0.0.0.0:*                           -
udp        0      0 ::1:15053               :::*                                -
```
