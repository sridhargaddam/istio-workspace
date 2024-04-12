> 📝 This is a continuation of the [work from Jacek Ewertowski](https://github.com/jewertow/istio-playground/blob/master/mesh-federation/README.md) and includes steps to verify Locality Load Balancing in a multi-mesh deployment. This will soon be merged in Jacek's repo.

## Locality Loadbalancing in a multi-mesh deployment

### Setup KIND clusters with locality info configured on the nodes.

1. Create the first cluster with region set to `east` and two nodes in different zones.
```shell
kind create cluster --config=east-cluster.yaml
```
2. Create a second cluster with region configured as `west` and a single node with zone set to `zone3`
```shell
kind create cluster --config=west-cluster.yaml
```
3. Setup contexts:
```shell
kind get kubeconfig --name east > east.kubeconfig
alias keast="KUBECONFIG=$(pwd)/east.kubeconfig kubectl"
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=$(pwd)/west.kubeconfig kubectl"
```
4. Install MetalLB on and configure IP address pools:
```shell
keast apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kwest apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
```
Before creating `IPAddressPool`, define CIDR based on kind network:
```shell
docker network inspect -f '{{.IPAM.Config}}' kind
```
Define east/west CIDRs as subnets of the `kind` network, e.g. if `kind` subnet is `172.18.0.0/16`,
east network could be `172.18.64.0/18` and west could be `172.18.128.0/18`, which will not overlap with node IPs.

CIDRs must have escaped slash before the network mask to make it usable with `sed`, e.g. `172.18.64.0\/18`.
```shell
export EAST_CLUSTER_CIDR="172.18.64.0\/18"
export WEST_CLUSTER_CIDR="172.18.128.0\/18"
```
```shell
sed "s/{{.cidr}}/$EAST_CLUSTER_CIDR/g" ip-address-pool.tmpl.yaml | keast apply -n metallb-system -f -
sed "s/{{.cidr}}/$WEST_CLUSTER_CIDR/g" ip-address-pool.tmpl.yaml | kwest apply -n metallb-system -f -
```

### Trust model

1. Download tools for certificate generation:
```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/common.mk -O common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
```

#### Common root

1. Generate certificates for east and west clusters:
```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="East Root CA" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="East Intermediate CA" \
  INTERMEDIATE_ORG=my-company.org \
  east-cacerts
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="West Intermediate CA" \
  INTERMEDIATE_ORG=my-company.org \
  west-cacerts
make -f common.mk clean
```

2. Create `cacert` secrets:
```shell
keast create namespace istio-system
keast create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=east/root-cert.pem \
  --from-file=ca-cert.pem=east/ca-cert.pem \
  --from-file=ca-key.pem=east/ca-key.pem \
  --from-file=cert-chain.pem=east/cert-chain.pem
```
```shell
kwest create namespace istio-system
kwest create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=west/root-cert.pem \
  --from-file=ca-cert.pem=west/ca-cert.pem \
  --from-file=ca-key.pem=west/ca-key.pem \
  --from-file=cert-chain.pem=west/cert-chain.pem
```

### Install Istio

```shell
helm template -s templates/istio.yaml . \
  --set localCluster=east \
  --set remoteCluster=west \
  --set sdsRootCaEnabled=false \
  | istioctl --kubeconfig=east.kubeconfig install -y -f -
```
```shell
helm template -s templates/istio.yaml . \
  --set localCluster=west \
  --set remoteCluster=east \
  --set sdsRootCaEnabled=false \
  | istioctl --kubeconfig=west.kubeconfig install -y -f -
```

### Configure routing

#### Ingress only (AUTO_PASSTHROUGH)

1. Configure east-west gateway and enable mtls:
```shell
keast apply -f auto-passthrough-gateway.yaml -n istio-system
kwest apply -f auto-passthrough-gateway.yaml -n istio-system
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
    ./gen-helloworld.sh \
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
TODO:: Verify why **Locality weighted distribution** is not working as expected across the mesh.
