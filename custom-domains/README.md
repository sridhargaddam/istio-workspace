## Using custom domains as part of service discovery

### Import and export services

1. Export httpbin from the west cluster:

In the hosts entry of the Gateway, we are configuring a custom domain of `*.global.mesh` along with `*.local`

```shell
kwest apply -f custom-domains/custom-domain-gateway.yaml -n istio-system
```

2. Enable mTLS, deploy a client in the east cluster and a server in the west cluster:
```shell
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
kwest create namespace httpbin
kwest label namespace httpbin istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
```

3. Import httpbin from west cluster to east cluster:
```shell
REMOTE_INGRESS_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
helm template -s templates/custom-domain/import-remote-svc.yaml . \
  --set eastwestGatewayIP=$REMOTE_INGRESS_IP \
  | keast apply -f -
```

Check endpoints in sleep's istio-proxy:
```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/sleep -n sleep | grep httpbin
```

4. Make a request from sleep to httpbin and this would fail as the remote eastwest gateway does not have information on where to route the request for custom domain:

```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -v httpbin.global.mesh:8000/headers
```

#### Using ServiceEntry with explicit address

5. Now lets create a ServiceEntry in the west cluster that points to the httpbin service IP.
```shell
HTTPBIN_SVC_IP=$(kwest get svc -l app=httpbin -n httpbin -o jsonpath='{.items[0].spec.clusterIP}')
helm template -s templates/custom-domain/custom-service-entry.yaml . \
  --set httpbinSvcIP=$HTTPBIN_SVC_IP \
  | kwest apply -f -
```

**Note:** The serviceEntry in the west cluster can be created even with PodIP as well.

6. Now, make a request from sleep to httpbin and this should work.
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -v httpbin.global.mesh:8000/headers
```

7. Lets delete the serviceEntry created above.
```shell
HTTPBIN_SVC_IP=$(kwest get svc -l app=httpbin -n httpbin -o jsonpath='{.items[0].spec.clusterIP}')
helm template -s templates/custom-domain/custom-service-entry.yaml . \
  --set httpbinSvcIP=$HTTPBIN_SVC_IP \
  | kwest delete -f -
```

#### Using ServiceEntry with service name

Instead of using serviceIP in the serviceEntry, we can simply use the serviceName itself in the ServiceEntry and the use-case would work.

```shell
kwest apply -f custom-domains/se-with-hostname.yaml
```
Sample output:
```shell
$ SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
$ keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -s httpbin.global.mesh:8000/headers | grep X-Forwarded-Client-Cert
    "X-Forwarded-Client-Cert": "By=spiffe://west.local/ns/httpbin/sa/httpbin;Hash=80390e43e622aa76209d09e015c19d47aae2e88711074447202f633408ed76ef;Subject=\"\";URI=spiffe://east.local/ns/sleep/sa/sleep"
```
