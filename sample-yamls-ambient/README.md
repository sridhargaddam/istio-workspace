# Sample commands to validate Istio Ambient mode using Sail Operator.

```shell
kind create cluster --config=../east-cluster.yaml
kind get kubeconfig --name east > east.kubeconfig
alias k="KUBECONFIG=$(pwd)/east.kubeconfig kubectl"
```

```shell
# From the directory where the sail-operator repo is cloned.
IMAGE=quay.io/sridhargaddam/sail-operator:latest make docker-build
IMAGE=quay.io/sridhargaddam/sail-operator:latest make docker-push
```

```shell
IMAGE=quay.io/sridhargaddam/sail-operator:latest make deploy
```

```shell
kubectl create ns istio-system || true
kubectl create ns istio-cni || true
kubectl create ns ztunnel || true
kubectl apply -f chart/samples/ambient/istio-sample.yaml
kubectl apply -f chart/samples/ambient/istiocni-sample.yaml
kubectl apply -f chart/samples/ambient/istioztunnel-sample.yaml
```

```shell
k create namespace sleep || true
k label namespace sleep istio.io/dataplane-mode=ambient --overwrite
k apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
```

```shell
k create namespace httpbin || true
k label namespace httpbin istio.io/dataplane-mode=ambient --overwrite
k apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
# To verify access to httpbin svc
k exec -it -n sleep deploy/sleep -- curl -s httpbin.httpbin.svc.cluster.local:8000/get
```

To verify that ztunnel successfully opened listening sockets inside the pod network ns, use the following command.
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
