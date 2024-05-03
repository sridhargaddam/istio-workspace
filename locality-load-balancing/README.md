## Locality Loadbalancing in a multi-mesh deployment

### Configure routing

#### Ingress only (AUTO_PASSTHROUGH)

1. Configure east-west gateway and enable mtls:
```shell
keast apply -f locality-load-balancing/auto-passthrough-gateway.yaml -n istio-system
kwest apply -f locality-load-balancing/auto-passthrough-gateway.yaml -n istio-system
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
```
#### Deploy the client and server pods

1. Deploy client app on the east cluster
```shell
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
helm template -s templates/sleep.yaml . --set zone=zone1 | keast apply -n sleep -f -
```
2. Deploy the helloworld server app on the east and west clusters.
Generate the HelloWorld YAML for each zone:

```shell
for ZONE in "zone1" "zone2" "zone3"; \
  do \
    ./locality-load-balancing/gen-helloworld.sh \
      --version "$ZONE" > "helloworld-${ZONE}.yaml"; \
  done
```
Deploy the helloworld server to each of the zones (using nodeSelectors) in both the clusters.
```shell
keast create namespace sample
keast label namespace sample istio-injection=enabled
keast apply -f helloworld-zone1.yaml -n sample
keast apply -f helloworld-zone2.yaml -n sample
kwest create namespace sample
kwest label namespace sample istio-injection=enabled
kwest apply -f helloworld-zone3.yaml -n sample
```

#### Import remote service as local (*.cluster.local)

1. Import helloworld from west cluster to east cluster:
```shell
EAST_WEST_GW_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
helm template -s templates/helloworld-workload.yaml . \
  --set eastwestGatewayIP=$EAST_WEST_GW_IP --set localityInfo="us/west/zone3" | keast apply -n sample -f -
```

2. Check endpoints for helloworld in sleep's istio-proxy:
```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/sleep -n sleep | grep helloworld
```

3. Make a request for helloworld service from the sleep pod. Traffic should be load balanced across all the pods equally.
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -sSL helloworld.sample.svc.cluster.local:5000/hello
```

### Locality failover

1. Apply a DestinationRule to trigger failover in the following pattern (east.zone1 -> east.zone2 -> west.zone3)
```shell
keast apply -n sample -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: helloworld
spec:
  host: helloworld.sample.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        maxRequestsPerConnection: 1
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failover:
          - from: east
            to: west
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
EOF
```
2. Verify that traffic now stays in the `east` cluster `zone1` where the sleep pod is also scheduled.
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
while true; do keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -sSL helloworld.sample.svc.cluster.local:5000/hello && sleep 1 ; done;
```

3. Trigger failover to `zone2` in `east` cluster.

For this, lets [drain the Envoy sidecar proxy](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/draining#draining) in `HelloWorld` pod of `east` cluster `zone1`

```shell
ZONE1_HELLOWORLD_POD=$(keast get pod -n sample -l app=helloworld -l version=zone1 -o jsonpath='{.items[0].metadata.name}')
keast exec $ZONE1_HELLOWORLD_POD -n sample -c istio-proxy -- curl -sSL -X POST 127.0.0.1:15000/drain_listeners
```
Now, verify that requests from sleep pod to helloworld are redirected to the pod in `zone2`
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
while true; do keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -sSL helloworld.sample.svc.cluster.local:5000/hello && sleep 1 ; done;
```

4. Lets now trigger failover to `west` cluster.

lets [drain the Envoy sidecar proxy](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/draining#draining) in `HelloWorld` pod of `east` cluster `zone2`as well.

```shell
ZONE2_HELLOWORLD_POD=$(keast get pod -n sample -l app=helloworld -l version=zone2 -o jsonpath='{.items[0].metadata.name}')
keast exec $ZONE2_HELLOWORLD_POD -n sample -c istio-proxy -- curl -sSL -X POST 127.0.0.1:15000/drain_listeners
```
Now, verify that requests from sleep pod to helloworld are redirected to the pod in `west` cluster `zone3`
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
while true; do keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -sSL helloworld.sample.svc.cluster.local:5000/hello && sleep 1 ; done;
```

Sample output would be as follows.
```shell
Hello version: zone3, instance: helloworld-zone3-5466b44b94-srvxf
Hello version: zone3, instance: helloworld-zone3-5466b44b94-srvxf
Hello version: zone3, instance: helloworld-zone3-5466b44b94-srvxf
```
With this, we have successfully configured locality failover.

Before trying out the next steps, lets delete the DestinationRule created earlier.
```shell
keast delete destinationrule -n sample helloworld
```

### Locality weighted distribution

In this exercise, we shall configure Istio to distribute the requests for `helloworld` pod using weighted distribution.

|Region|Zone  |%traffic|
|--|--|--|
| east | zone1  | 10% |
| east | zone2  | 10% |
| west | zone3  | 80% |

#### Configure Weighted distribution

1.  Apply a DestinationRule as shown below.

```shell
keast apply -n sample -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: helloworld
spec:
  host: helloworld.sample.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
        - from: east/zone1/*
          to:
            "east/zone1/*": 10
            "east/zone2/*": 10
            "us/west/zone3/*": 80
    outlierDetection:
      consecutive5xxErrors: 100
      interval: 1s
      baseEjectionTime: 1m
EOF
```

2. Now, verify that requests from sleep pod to helloworld are properly loadbalanced as per the configured weights.

```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
while true; do keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -sSL helloworld.sample.svc.cluster.local:5000/hello && sleep 1 ; done;
```

Sample output would be as follows.

```shell
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
Hello version: zone1, instance: helloworld-zone1-784c57876d-2cwdr
Hello version: zone2, instance: helloworld-zone2-8584c5d7bf-xhdfw
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
Hello version: zone3, instance: helloworld-zone3-666965666b-k2p9m
```
