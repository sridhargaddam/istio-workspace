### Multi-primary Istio setup

> **Ref:** https://istio.io/latest/docs/setup/install/multicluster/verify/
> https://github.com/jewertow/istio-playground

1. Create a KIND cluster named east:
```shell
kind create cluster --name east --config=<<EOF
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
networking:
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.255.10.0/24"
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
```

2. Create a KIND cluster named west:
```shell
kind create cluster --name west --config=<<EOF
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
networking:
  podSubnet: "10.20.0.0/16"
  serviceSubnet: "10.255.20.0/24"
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
```

3. Setup contexts:
```shell
kind get kubeconfig --name east > east.kubeconfig
alias keast="KUBECONFIG=east.kubeconfig kubectl"
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=west.kubeconfig kubectl"
```

4. Install MetalLB on the Kind clusters and configure IP address pools:
```shell
keast apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
kwest apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
```

Before creating `IPAddressPool`, identify the CIDR used by the kind network:
```shell
docker network inspect -f '{{.IPAM.Config}}' kind
```

Define east/west CIDRs as subnets of the `kind` network, e.g. if `kind` subnet is `172.18.0.0/16`,
east network could be `172.18.64.0/18` and west could be `172.18.128.0/18`, which will not overlap with node IPs.

CIDRs must have escaped slash before the network mask to make it usable with `sed`, e.g. `172.18.64.0\/18`.
```shell
export EAST_CLUSTER_CIDR="172.18.64.0\/18"
```
```shell
export WEST_CLUSTER_CIDR="172.18.128.0\/18"
```
```shell
sed "s/{{.cidr}}/$EAST_CLUSTER_CIDR/g" ip-address-pool.tmpl.yaml | keast apply -n metallb-system -f -
sed "s/{{.cidr}}/$WEST_CLUSTER_CIDR/g" ip-address-pool.tmpl.yaml | kwest apply -n metallb-system -f -
```



