# Sample validation commands

```shell
kind create cluster --config=../east-cluster.yaml
kind get kubeconfig --name east > east.kubeconfig
alias k="KUBECONFIG=$(pwd)/east.kubeconfig kubectl"
```

```shell
istioctl install -y --set profile=demo
```

```shell
k create namespace sleep
k label namespace sleep istio-injection=enabled
k apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
```

```shell
k create namespace httpbin
k label namespace httpbin istio-injection=enabled
k apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
# On OpenShift, we can use the following yaml - https://raw.githubusercontent.com/maistra/istio/refs/heads/maistra-2.6/samples/httpbin/httpbin.yaml
# To verify access to httpbin svc
k exec -it -n sleep deploy/sleep -- curl -s httpbin.httpbin.svc.cluster.local:8000/get
```

```shell
k create namespace http-echo
k label namespace http-echo istio-injection=enabled
k apply -f https://gist.githubusercontent.com/sridhargaddam/67f5485c1569af02e312c2bda4d6edab/raw/8ad451279569eeee6ee157fa018627f984425078/http-echo -n http-echo
# To verify access to http-echo svc
k exec -it -n sleep deploy/sleep -- curl -s http-echo.http-echo.svc.cluster.local
```

```shell
k create namespace http-headers
k label namespace http-headers istio-injection=enabled
k apply -f https://gist.githubusercontent.com/sridhargaddam/dfac796d00a2072af3f7e1ab8bb481ae/raw/7b6de241d50d701c5de7469242b05fa00b1bf918/http-headers -n http-headers
# To verify access to http-headers svc
k exec -it -n sleep deploy/sleep -- curl -H "Custom-Header: CustomValue" -s http-headers.http-headers.svc.cluster.local/get
{
  "args": {}, 
  "headers": {
    "Accept": "*/*", 
    "Custom-Header": "CustomValue", 
    "Host": "http-headers.http-headers.svc.cluster.local", 
    "User-Agent": "curl/8.9.0"
  }, 
  "origin": "10.244.1.2", 
  "url": "http://http-headers.http-headers.svc.cluster.local/get"
}
```
