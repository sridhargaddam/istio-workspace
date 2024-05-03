## Importing a Service with multiple ports

#### Deploy client and server pods

1. Deploy client app on the east cluster
```shell
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
```
2. Create a multi-port service in west cluster.

```shell
kwest create namespace echo-ns
kwest label namespace echo-ns istio-injection=enabled
kwest apply -f multi-port-service/http-echo.yaml -n echo-ns
```

### Import and Export Services

1. Export http-echo service from west cluster
```shell
kwest apply -f multi-port-service/eastwest-gateway.yaml -n istio-system
```

2. Enable mtls:
```shell
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
```

3. Import http-echo service in the east cluster

```shell
REMOTE_INGRESS_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
helm template -s templates/multi-port-service/import-echo-server.yaml . \
  --set eastwestGatewayIP=$REMOTE_INGRESS_IP \
  | keast apply -f -
```

Check endpoints in sleep's istio-proxy:
```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/sleep -n sleep | grep echo
```

4. Test a request from sleep to echo-server:
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -s echo-server.echo-ns.svc.cluster.local
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -s echo-server.echo-ns.svc.cluster.local:90
```

Sample output would be as follows.
```shell
"[8080] hello world..."
"[9090] hello world..."
```

