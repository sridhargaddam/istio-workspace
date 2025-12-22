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
          image: quay.io/sridhargaddam/pilot:ovnk-udn-1.28
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
    Note: Please note that the above Istio CR uses a custom pilot image, where the Istio EndpointSlice controller builds its endpoints using the UDN
    network in sidecar mode. The pilot image is built by updating the Istio EndpointSlice controller to use "k8s.ovn.org/service-name" as the LabelServiceName
    instead of the default value defined [here](https://github.com/kubernetes/api/blob/71f613bc35100524b91fba5c07de2fbc8722b1c5/discovery/v1/well_known_labels.go#L21).

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
    command terminated with exit code 56
    ```
   
    Logs from ztunnel pod where sleep pod is scheduled.
    ```shell
   2025-12-22T15:34:02.820192Z    error    access    connection complete    src.addr=3.3.0.9:51874 src.workload="sleep-868c754c4b-gmz2p"
   src.namespace="sleep" src.identity="spiffe://cluster.local/ns/sleep/sa/sleep" dst.addr=10.131.1.42:15008 dst.hbone_addr=10.131.1.42:8000
   dst.service="httpbin.httpbin.svc.cluster.local" dst.workload="httpbin-7bfcbb4dbd-6fxmz" dst.namespace="httpbin"
   dst.identity="spiffe://cluster.local/ns/httpbin/sa/httpbin" direction="outbound" bytes_sent=0 bytes_recv=0 duration="3088ms"
   error="io error: No route to host (os error 113)"
    ```

   Workload endpoints seen by ztunnel.
   ```shell
   $: istioctl zc workloads -n ztunnel | grep HBONE
   httpbin                                          httpbin-7bfcbb4dbd-6fxmz                                      10.131.1.42   user-rhos-01-07-h9cvb-worker-0-zlgh6 None     HBONE
   sleep                                            sleep-868c754c4b-gmz2p                                        10.131.1.41   user-rhos-01-07-h9cvb-worker-0-zlgh6 None     HBONE
   ```

Observations:

We are unable to connect from `sleep` to the `httpbin` pod because `ztunnel` does not see the endpoint IP on the UDN network and
only sees the IP from the default K8s network. This suggests that the change to monitor mirrored EndpointSlices is not working
in ambient mode. We need to investigate how ambient constructs endpoints and update the code accordingly.

