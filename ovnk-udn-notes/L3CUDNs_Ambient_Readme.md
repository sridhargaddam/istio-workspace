# POC: L3 Primary CUDNs and Ambient Mode with Sail Operator

### Prerequisites:
* Access to an OCP 4.18+ cluster that includes OVN-K User Defined Network (UDN) Support.

### Steps:

1. Let's create the necessary namespaces for Sail Operator and Istio components.

    ```shell
    namespaces_without_injection=("istio-system" "istio-cni" "ztunnel" "sail-operator")
    for ns in "${namespaces_without_injection[@]}"; do
      cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: $ns
      labels:
        k8s.ovn.org/primary-user-defined-network: ""
    EOF
    done
    ```

1. Create the `sample` and `httpbin` namespaces with the required labels.

    ```shell
    namespaces_with_injection=("sleep" "httpbin" "bookinfo")
    for ns in "${namespaces_with_injection[@]}"; do
      cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: $ns
      labels:
        k8s.ovn.org/primary-user-defined-network: ""
        istio.io/dataplane-mode: ambient
    EOF
    done
    ```

1. Create a Layer 3 (L3) Primary `ClusterUserDefinedNetwork` CR named `ossm-l3-cudn`

    ```shell
    cat <<EOF | oc apply -f -
    apiVersion: k8s.ovn.org/v1
    kind: ClusterUserDefinedNetwork
    metadata:
      name: ossm-l3-cudn
    spec:
      namespaceSelector:
        matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: ["sleep", "httpbin", "bookinfo", "istio-system", "istio-cni", "sail-operator", "ztunnel"]
      network:
        topology: Layer3
        layer3:
          role: Primary
          subnets:
            - cidr: 3.3.0.0/16
              hostSubnet: 24
    EOF
    ```

1. Clone the Sail Operator repo and install the operator.

    ```shell
    git clone https://github.com/istio-ecosystem/sail-operator.git
    cd sail-operator
    git checkout release-1.28
    make deploy
    ```

1. Wait for the sail-operator to be installed. Once its up and running, let's install Istio by creating the `IstioCNI`, `ztunnel` and `Istio` CRs.

    ```shell
    cat <<EOF | oc apply -f -
    apiVersion: sailoperator.io/v1
    kind: IstioCNI
    metadata:
      name: default
    spec:
      profile: ambient
      version: v1.28.1
      namespace: istio-cni
    EOF
    ```

    ```shell
    cat <<EOF | oc apply -f -
    apiVersion: sailoperator.io/v1
    kind: Istio
    metadata:
      name: default
    spec:
      version: v1.28.1
      namespace: istio-system
      profile: ambient
      updateStrategy:
        type: InPlace
      values:
        pilot:
          trustedZtunnelNamespace: "ztunnel"
          image: quay.io/sridhargaddam/pilot:ovnk-udn-1.28-ambient
          podAnnotations:
            k8s.ovn.org/open-default-ports: |
              - protocol: tcp
                port: 15017
              - protocol: tcp
                port: 15012
              - protocol: tcp
                port: 443
              - protocol: tcp
                port: 15010
              - protocol: tcp
                port: 15014   
        global:
          imagePullPolicy: "Always"
    EOF
    ```

    Note: Please note that the Istio CR above uses a custom pilot image. In this setup, the Istio EndpointSlice controller builds
    endpoints using the UDN network, and the ambient workload builder uses mirrored EndpointSlices for pod IPs instead of the IPs
    from the pod spec.

    ```shell
    cat <<EOF | oc apply -f -
    apiVersion: sailoperator.io/v1
    kind: ZTunnel
    metadata:
      name: default
    spec:
      version: v1.28.1
      namespace: ztunnel
    EOF
    ```

1. Deploy `sleep` and `httpbin` pods in their respective namespaces.

    ```shell
    oc apply -n sleep -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml
    oc apply -n httpbin -f https://raw.githubusercontent.com/sridhargaddam/istio-workspace/refs/heads/main/sample-yamls-ambient/httpbin.yaml
    ```

1. Verify that the mirrored endpointslices are created by OVNK. 

    ```shell
    kubectl get endpointslices -n httpbin
    NAME            ADDRESSTYPE   PORTS   ENDPOINTS     AGE
    httpbin-vk9fm   IPv4          8000    10.131.1.42   8m5s
    httpbin-vs7cz   IPv4          8000    3.3.0.11      8m3s
    ```

1. Now, lets verify if we can connect to httpbin pod from the sleep pod.

    ```shell
    kubectl exec -it -n sleep deploy/sleep -- curl -s httpbin.httpbin.svc.cluster.local:8000/get
    {
    "args": {},
    "headers": {
    "Accept": "*/*",
    "Host": "httpbin.httpbin.svc.cluster.local:8000",
    "User-Agent": "curl/8.17.0"
    },
    "origin": "::ffff:3.3.1.9",
    "url": "http://httpbin.httpbin.svc.cluster.local:8000/get"
    }
    ```
   
    Logs from ztunnel pod confirm that traffic is mTLS encrypted and connect using the UDN IPs.

    ```shell
    info    access    connection complete    src.addr=3.3.1.9:33938 src.workload="sleep-868c754c4b-spq8x" src.namespace="sleep"
    src.identity="spiffe://cluster.local/ns/sleep/sa/sleep" dst.addr=3.3.1.11:15008 dst.hbone_addr=3.3.1.11:8000
    dst.service="httpbin.httpbin.svc.cluster.local" dst.workload="httpbin-7bfcbb4dbd-vvrxq" dst.namespace="httpbin"
    dst.identity="spiffe://cluster.local/ns/httpbin/sa/httpbin" direction="inbound" bytes_sent=471 bytes_recv=105 duration="1ms"
    2025-12-24T15:28:27.329981Z    info    access    connection complete    src.addr=3.3.1.9:37418 src.workload="sleep-868c754c4b-spq8x"
    src.namespace="sleep" src.identity="spiffe://cluster.local/ns/sleep/sa/sleep" dst.addr=3.3.1.11:15008 dst.hbone_addr=3.3.1.11:8000
    dst.service="httpbin.httpbin.svc.cluster.local" dst.workload="httpbin-7bfcbb4dbd-vvrxq" dst.namespace="httpbin"
    dst.identity="spiffe://cluster.local/ns/httpbin/sa/httpbin" direction="outbound" bytes_sent=105 bytes_recv=471 duration="2ms"
    ```

   Workload endpoints seen by ztunnel.
   ```shell
   istioctl zc workloads -n ztunnel | grep HBONE
   httpbin    httpbin-7bfcbb4dbd-vvrxq    3.3.1.11      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   sleep      sleep-868c754c4b-spq8x      3.3.1.9       user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   ```
1. Deploy the Bookinfo pods along with the Bookinfo Gateway to verify external connectivity.

    ```shell
    oc apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml
    oc apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo-versions.yaml
    ```

   Install gateway API CRDs if they are not already installed.
    ```shell
    kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
      { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.1.0" | kubectl apply -f -; }
    ```

   Deploy the bookinfo gateway.
    ```shell
    kubectl apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/gateway-api/bookinfo-gateway.yaml
    kubectl wait -n bookinfo --for=condition=programmed gtw bookinfo-gateway
    ```

1. Confirm that the Bookinfo productpage is accessible from outside the cluster.

    ```shell
    export INGRESS_HOST=$(kubectl get gtw bookinfo-gateway -n bookinfo -o jsonpath='{.status.addresses[0].value}')
    export INGRESS_PORT=$(kubectl get gtw bookinfo-gateway -n bookinfo -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
    export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
    curl -s -o /dev/null -w "%{http_code}\n" http://${GATEWAY_URL}/productpage
    200
    ```

   You should also be able to access http://${GATEWAY_URL}/productpage from a web browser.

1. Workload endpoints seen by ztunnel.

   ```shell
   istioctl zc workloads -n ztunnel | grep HBONE
   bookinfo     details-v1-766844796b-mjw6d      3.3.1.14      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   bookinfo     productpage-v1-54bb874995-pmwdz  3.3.2.13      user-rhos-01-06-9pzb8-worker-0-z7x95 None     HBONE
   bookinfo     ratings-v1-5dc79b6bcd-x2ggw      3.3.1.16      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   bookinfo     reviews-v1-598b896c9d-tgktn      3.3.1.18      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   bookinfo     reviews-v2-556d6457d-62xpk       3.3.1.20      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   bookinfo     reviews-v3-564544b4d6-v2qdx      3.3.1.22      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   httpbin      httpbin-7bfcbb4dbd-vvrxq         3.3.1.11      user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   sleep        sleep-868c754c4b-spq8x           3.3.1.9       user-rhos-01-06-9pzb8-worker-0-clflq None     HBONE
   ```