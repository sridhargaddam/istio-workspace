## Load balancing in Mesh Federation

### Create Auto Passthrough Ingress Gateway

1. Create an eastwest gateway in the west cluster

```shell
kwest apply -f auto-passthrough-gateway.yaml -n istio-system
```

2. Enable mTLS

```shell
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
```

3. Deploy a fortio client on the east cluster.

```shell
keast create namespace fortio
keast label namespace fortio istio-injection=enabled
keast apply -f load-balancing/fortio-deploy.yaml -n fortio
```

5. Create httpbin server pods on the east and west clusters.

```shell
keast create namespace httpbin
keast label namespace httpbin istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
kwest create namespace httpbin
kwest label namespace httpbin istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
```

### Import remote httpbin pods as endpoints of local service

1. Import httpbin pods from west cluster to east cluster.

```shell
REMOTE_INGRESS_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
helm template -s templates/load-balancing/import-as-local.yaml . \
  --set eastwestGatewayIP=$REMOTE_INGRESS_IP \
  | keast apply -f -
```

3. Check endpoints for httpbin in fortio's istio-proxy and you should see two endpoints.
```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/fortio-deploy -n fortio | grep httpbin
```

### Verify load balancing

1. Make a request for httpbin service from the fortio pod. Traffic should be load balanced across all the pods equally.

```shell
FORTIO_POD_NAME=$(keast get pods -l app=fortio -n fortio -o jsonpath='{.items[0].metadata.name}')
keast exec $FORTIO_POD_NAME -n fortio -c fortio -- /usr/bin/fortio curl  httpbin.httpbin.svc.cluster.local:8000/headers
```

2. Scale local deployment of httpbin service:
```shell
keast scale deployment httpbin -n httpbin --replicas 2
```

3. Sidecar of fortio app should now have 3 endpoints for httpbin.

```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/fortio-deploy -n fortio | grep httpbin
```

4.  Make a request for httpbin service from the fortio pod. Traffic should be load balanced across all the three pods equally (2 pods in east and one pod in west cluster).

```shell
keast exec $FORTIO_POD_NAME -n fortio -c fortio -- /usr/bin/fortio curl  httpbin.httpbin.svc.cluster.local:8000/headers
```

5. Scale the remote deployment of httpbin service:
```shell
kwest scale deployment httpbin -n httpbin --replicas 2
```

If you make a request from the fortio client to httpbin, you should see that the new instances of httpbin service in the west cluster do not receive any traffic.

```shell
while true; do keast exec $FORTIO_POD_NAME -n fortio -c fortio -- /usr/bin/fortio curl httpbin.httpbin.svc.cluster.local:8000/headers; sleep 0.5; done
```

This is a known issue with Istio. To workaround the issue, we can configure a `DestinationRule` with `maxRequestsPerConnection` to limit the number of requests per connection.
- [https://github.com/istio/istio/issues/31549](https://github.com/istio/istio/issues/31549)
- [https://github.com/envoyproxy/envoy/issues/15071](https://github.com/envoyproxy/envoy/issues/15071)
- [https://discuss.istio.io/t/need-help-understanding-load-balancing-between-clusters/9552](https://discuss.istio.io/t/need-help-understanding-load-balancing-between-clusters/9552)

6. Let's create a DestinationRule on the west cluster with `maxRequestsPerConnection` set to 2 for this exercise.

```shell
kwest apply -n httpbin -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: httpbin-connection-pool
spec:
  host: httpbin.httpbin.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        http1MaxPendingRequests: 4
        maxRequestsPerConnection: 2
EOF
```

7. Let's scale down the httpbin replicas to 1 on east cluster, to simply the understanding of how the requests were load-balanced.

```shell
keast scale deployment httpbin -n httpbin --replicas 1
```

8. Let's monitor the logs of `istio-proxy` pod on the west cluster in a new window.

```shell
kwest logs -f -n httpbin -l app=httpbin -c istio-proxy --prefix
```

9. Use fortio client to make requests to the httpbin service.

```shell
while true; do keast exec $FORTIO_POD_NAME -n fortio -c fortio -- /usr/bin/fortio curl httpbin.httpbin.svc.cluster.local:8000/headers; sleep 0.5; done
```

[comment]: # (keast exec $FORTIO_POD_NAME -n fortio -c fortio -- /usr/bin/fortio load -c 12 -qps 2 -n 12 http://httpbin.httpbin.svc.cluster.local:8000/headers)

As a sample output, you would observe that 50% of the requests made to httpbin would be directed to the west cluster and distributed among the active pods within the west cluster.

```shell
[pod/httpbin-868cdd659c-nl9j4/istio-proxy] [2024-05-19T15:17:03.792Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 535 1 0 "-" "fortio.org/fortio-1.60.3" "c5342961-11b6-9419-93ab-cb1a9389cec6" "httpbin.httpbin.svc.cluster.local:8000" "10.244.1.17:80" inbound|80|| 127.0.0.6:43763 10.244.1.17:80 10.244.1.15:46910 outbound_.8000_._.httpbin.httpbin.svc.cluster.local default
[pod/httpbin-868cdd659c-tjdbr/istio-proxy] [2024-05-19T15:17:04.992Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 535 1 1 "-" "fortio.org/fortio-1.60.3" "ba823a3f-27bc-4f2d-85f9-67a8653fa7ff" "httpbin.httpbin.svc.cluster.local:8000" "10.244.1.16:80" inbound|80|| 127.0.0.6:53365 10.244.1.16:80 10.244.1.15:59594 outbound_.8000_._.httpbin.httpbin.svc.cluster.local default
[pod/httpbin-868cdd659c-nl9j4/istio-proxy] [2024-05-19T15:17:06.193Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 535 1 1 "-" "fortio.org/fortio-1.60.3" "1bb23447-ad75-453c-9dd1-22565cd78741" "httpbin.httpbin.svc.cluster.local:8000" "10.244.1.17:80" inbound|80|| 127.0.0.6:45399 10.244.1.17:80 10.244.1.15:46910 outbound_.8000_._.httpbin.httpbin.svc.cluster.local default
[pod/httpbin-868cdd659c-tjdbr/istio-proxy] [2024-05-19T15:17:07.392Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 535 1 0 "-" "fortio.org/fortio-1.60.3" "f0d3050c-cfac-471e-aa80-1204b8b166ac" "httpbin.httpbin.svc.cluster.local:8000" "10.244.1.16:80" inbound|80|| 127.0.0.6:40971 10.244.1.16:80 10.244.1.15:59594 outbound_.8000_._.httpbin.httpbin.svc.cluster.local default
[pod/httpbin-868cdd659c-nl9j4/istio-proxy] [2024-05-19T15:17:08.593Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 535 1 1 "-" "fortio.org/fortio-1.60.3" "47aa0683-a986-4f95-991e-8489172d6e95" "httpbin.httpbin.svc.cluster.local:8000" "10.244.1.17:80" inbound|80|| 127.0.0.6:50571 10.244.1.17:80 10.244.1.15:46910 outbound_.8000_._.httpbin.httpbin.svc.cluster.local default
[pod/httpbin-868cdd659c-tjdbr/istio-proxy] [2024-05-19T15:17:09.792Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 535 1 1 "-" "fortio.org/fortio-1.60.3" "49333421-aeed-4a84-b56a-b7e9832fe87a" "httpbin.httpbin.svc.cluster.local:8000" "10.244.1.16:80" inbound|80|| 127.0.0.6:53473 10.244.1.16:80 10.244.1.15:59594 outbound_.8000_._.httpbin.httpbin.svc.cluster.local default
```
