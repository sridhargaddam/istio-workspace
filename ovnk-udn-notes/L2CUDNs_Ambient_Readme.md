# POC: L2 Primary CUDNs and Ambient Mode with Sail Operator

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
        cudn-network: "true"
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
        cudn-network: "true"
    EOF
    done
    ```

1. Create a Layer 2 (L2) Primary `ClusterUserDefinedNetwork` CR named `ossm-l2-cudn`

    ```shell
    cat <<EOF | oc apply -f -
    apiVersion: k8s.ovn.org/v1
    kind: ClusterUserDefinedNetwork
    metadata:
      name: ossm-l2-cudn
    spec:
      namespaceSelector:
        matchLabels:
          cudn-network: "true"
      network:
        topology: Layer2
        layer2:
          role: Primary
          subnets:
            - 2.2.0.0/16
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
      values:
        cni:
          forceIptablesBinary: nft
          image: quay.io/sridhargaddam/install-cni:ovnk-udn-1.28-ambient
          ambient:
            reconcileIptablesOnStartup: true
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
          env:
            PILOT_ENABLE_OVNK_UDN: "true"
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
    oc apply -n sleep -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/sleep/sleep.yaml
    oc apply -n httpbin -f https://raw.githubusercontent.com/sridhargaddam/istio-workspace/refs/heads/main/sample-yamls-ambient/httpbin.yaml
    ```
   
1. Verify that the mirrored endpointslices are created by OVNK. 

    ```shell
    kubectl get endpointslices -n httpbin
    NAME            ADDRESSTYPE   PORTS   ENDPOINTS     AGE
    httpbin-c92qx   IPv4          8000    10.131.0.27   2m5s
    httpbin-jn5b2   IPv4          8000    2.2.0.36      2m3s
    ```

1. Now, lets verify if we can connect to httpbin pod from the sleep pod.

    ```shell
    kubectl exec -it -n sleep deploy/sleep -- curl -s httpbin.httpbin.svc.cluster.local:8000/get
    {
    "args": {},
    "headers": {
    "Accept": "*/*",
    "Host": "httpbin.httpbin.svc.cluster.local:8000",
    "User-Agent": "curl/8.16.0"
    },
    "origin": "::ffff:2.2.0.34",
    "url": "http://httpbin.httpbin.svc.cluster.local:8000/get"
    }
    ```
   
    Logs from ztunnel pod confirm that traffic is mTLS encrypted and connect using the UDN IPs.

    ```shell
    info    access    connection complete    src.addr=2.2.0.34:53140 src.workload="sleep-7cccf64445-xbcqd" src.namespace="sleep" src.identity="spiffe://cluster.local/ns/sleep/sa/sleep" dst.addr=2.2.0.36:15008 dst.hbone_addr=2.2.0.36:8000 dst.service="httpbin.httpbin.svc.cluster.local" dst.workload="httpbin-6d9f7896d9-vbvkl" dst.namespace="httpbin" dst.identity="spiffe://cluster.local/ns/httpbin/sa/httpbin" direction="inbound" bytes_sent=472 bytes_recv=105 duration="4ms"
    info    access    connection complete    src.addr=2.2.0.34:60762 src.workload="sleep-7cccf64445-xbcqd" src.namespace="sleep" src.identity="spiffe://cluster.local/ns/sleep/sa/sleep" dst.addr=2.2.0.36:15008 dst.hbone_addr=2.2.0.36:8000 dst.service="httpbin.httpbin.svc.cluster.local" dst.workload="httpbin-6d9f7896d9-vbvkl" dst.namespace="httpbin" dst.identity="spiffe://cluster.local/ns/httpbin/sa/httpbin" direction="outbound" bytes_sent=105 bytes_recv=472 duration="7ms"
    ```

   Workload endpoints seen by ztunnel.
   ```shell
   istioctl zc workloads -n ztunnel | grep HBONE
   httpbin   httpbin-6d9f7896d9-vbvkl          2.2.0.36    user-rhos-01-01-4lvvd-worker-0-cqbfc None     HBONE
   sleep     sleep-7cccf64445-xbcqd            2.2.0.34    user-rhos-01-01-4lvvd-worker-0-cqbfc None     HBONE
   ```