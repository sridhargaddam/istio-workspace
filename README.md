# istio-workspace

> 📝 This is a continuation of the [work from Jacek Ewertowski](https://github.com/jewertow/istio-playground/blob/master/mesh-federation/README.md) and includes steps to verify the [following use-cases](https://github.com/sridhargaddam/istio-workspace/tree/main#try-out) in a multi-mesh deployment.

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
  | istioctl --kubeconfig=east.kubeconfig install -y -f -
```
```shell
helm template -s templates/istio.yaml . \
  --set localCluster=west \
  --set remoteCluster=east \
  --set eastwestIngressEnabled=true \
  | istioctl --kubeconfig=west.kubeconfig install -y -f -
```

#### Try out

1. [Load-balancing in Mesh Federation](./load-balancing/README.md)
2. [Locality based load-balancing](./locality-load-balancing/README.md)
3. [Importing a Service with multiple ports](./multi-port-service/README.md)
4. [Using custom domains as part of service discovery](./custom-domains/README.md)

