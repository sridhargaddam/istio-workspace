### Multi-primary Istio setup

> **Ref:** 
> https://istio.io/latest/docs/setup/install/multicluster/verify/
> 
> https://github.com/jewertow/istio-playground

1. Create a kind cluster named `east`:
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

2. Create a kind cluster named `west`:
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

4. Install MetalLB on the kind clusters and configure IP address pools:
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

5. Configure `east` cluster as Primary cluster.
```shell
$ cat <<EOF > istio-config-east.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: east
      network: network1
EOF
```

Apply the configuration to `east` cluster:
```shell
istioctl install --kubeconfig=east.kubeconfig -f istio-config-east.yaml
```
6. Configure `west` cluster as Primary cluster.
```shell
$ cat <<EOF > istio-config-west.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: west
      network: network1
EOF
```

Apply the configuration to `west` cluster:
```shell
istioctl install --kubeconfig=west.kubeconfig -f istio-config-west.yaml
```
 
7. Enable K8s API access between the clusters.

Install a remote secret in `west` cluster that provides access to `east` cluster API server.
```shell
istioctl create-remote-secret \
    --kubeconfig=east.kubeconfig \
    --name=east | \
    kwest apply -f -"
```

Install a remote secret in `east` cluster that provides access to `west` cluster API server.
```shell
istioctl create-remote-secret \
    --kubeconfig=west.kubeconfig \
    --name=west | \
    keast apply -f -"
```

8. Let's verify that multi-primary installation is successful.

Let's deploy HelloWorld service in both the clusters with different versions in each cluster.
We shall deploy version v1 in `east` cluster and version v2 in `west` cluster.

```shell
keast create namespace sample
kwest create namespace sample
```

Enable automatic sidecar injection for the `sample` namespace:
```shell
keast label namespace sample istio-injection=enabled
kwest label namespace sample istio-injection=enabled
```

```shell
keast apply -f helloworld.yaml -l service=helloworld -n sample
kwest apply -f helloworld.yaml -l service=helloworld -n sample
```

9. Deploy HelloWorld-v1 app to `east` cluster

```shell
keast apply -f helloworld.yaml -l version=v1 -n sample
keast wait --for=condition=ready pod -l app=helloworld -n sample 
```

10. Deploy HelloWorld-v2 app to `west` cluster

```shell
kwest apply -f helloworld.yaml -l version=v2 -n sample
kwest wait --for=condition=ready pod -l app=helloworld -n sample
```

11. Deploy the `sleep` app in both the clusters.

```shell
keast apply -f sleep.yaml -n sample
kwest apply -f sleep.yaml -n sample
```

Wait until the sleep pods enter Running state.
```shell
keast wait --for=condition=ready pod -l app=sleep -n sample
kwest wait --for=condition=ready pod -l app=sleep -n sample
```

12. Verify cross-cluster traffic.

To make sure that cross-cluster load balancing is working, try calling the HelloWorld
service a few times using the `sleep` pod. Also, test accessing the HelloWorld service
from both the clusters to confirm that load balancing is working properly.

```shell
keast exec -n sample -c sleep "$(keast get pod -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello
```

Repeat the above request several times and verify that loadbalancing is happening between v1 and v2 apps:

```shell
Hello version: v2, instance: helloworld-v2-758dd55874-6x4t8
Hello version: v1, instance: helloworld-v1-86f77cd7bd-cpxhv
```

Repeat the request from `west` cluster.

```shell
kwest exec -n sample -c sleep "$(kwest get pod -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello
```

Repeat the above request several times and verify that loadbalancing is happening between v1 and v2 apps:

```shell
Hello version: v1, instance: helloworld-v1-86f77cd7bd-cpxhv
Hello version: v2, instance: helloworld-v2-758dd55874-6x4t8
```

You successfully installed and verified Istio on multiple clusters!


