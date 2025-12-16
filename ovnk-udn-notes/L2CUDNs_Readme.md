# POC: Layer 2 ClusterUserDefinedNetwork with Sail Operator on an OCP 4.18+ Cluster

### Prerequisites:
* Access to an OCP 4.18+ cluster that includes OVN-K User Defined Network (UDN) Support.

### Steps:

1. Let's create the necessary namespaces for Sail Operator and Istio components.

    ```shell
    namespaces_without_injection=("istio-system" "istio-cni" "sail-operator")
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
        istio-injection: "enabled"
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
        matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: ["sleep", "httpbin", "bookinfo", "istio-system", "istio-cni", "sail-operator"]
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

1. Wait for the sail-operator to be installed. Once its up and running, let's install Istio by creating the `IstioCNI` and `Istio` CRs.

    ```shell
    cat <<EOF | oc apply -f -
    apiVersion: sailoperator.io/v1
    kind: IstioCNI
    metadata:
      name: default
    spec:
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
      profile: openshift
      updateStrategy:
        type: InPlace
      values:
        pilot:
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

1. Deploy `sleep` and `httpbin` pods in their respective namespaces.

    ```shell
    oc apply -n sleep -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml
    oc apply -n httpbin -f https://raw.githubusercontent.com/sridhargaddam/istio-workspace/refs/heads/main/sample-yamls-ambient/httpbin.yaml
    ```

1. If you query the Istio endpoints using the `istioctl proxy-config` command, you'll notice that the endpoint IP associated with `httpbin` points to IP on UDN network and not the default network.

    ```shell
    istioctl proxy-config endpoints deploy/sleep -n sleep | grep httpbin
    2.2.0.6:8000  HEALTHY   OK    outbound|8000||httpbin.httpbin.svc.cluster.local
    ```

    ```shell
    kubectl get endpointslices -n httpbin
    NAME            ADDRESSTYPE   PORTS   ENDPOINTS     AGE
    httpbin-7rwzj   IPv4          8000    10.128.2.27   179m
    httpbin-mcsdn   IPv4          8000    2.2.0.6       179m
    ```

1. Now, lets verify that we are able to reach from the sleep pod to the httpbin pod.

    ```shell
    kubectl exec -it -n sleep deploy/sleep -- curl -s httpbin.httpbin.svc.cluster.local:8000/get
    {
      "args": {},
      "headers": {
        "Accept": "*/*",
        "Host": "httpbin.httpbin.svc.cluster.local:8000",
        "User-Agent": "curl/8.12.1",
        "X-Envoy-Attempt-Count": "1",
        "X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/httpbin/sa/httpbin;Hash=bb33a57a8fa324deb1a4a3430f306fa2fa36e3157b79ccb1aab03518d8b5d1d4;Subject=\"\";URI=spiffe://cluster.local/ns/sleep/sa/sleep"
      },
      "origin": "::ffff:127.0.0.6",
      "url": "http://httpbin.httpbin.svc.cluster.local:8000/get"
    }
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
    curl http://${GATEWAY_URL}/productpage
    ```

    You should also be able to access http://${GATEWAY_URL}/productpage from a web browser.

1. If you check the Istio endpoints, you'll see that the endpoint IPs point to the UDN IPs of the Bookinfo pods.

    ```shell
    istioctl proxy-config endpoints -n bookinfo deploy/productpage-v1 | grep reviews
    2.2.0.35:9080                 HEALTHY     OK                outbound|9080||reviews-v1.bookinfo.svc.cluster.local
    2.2.0.35:9080                 HEALTHY     OK                outbound|9080||reviews.bookinfo.svc.cluster.local
    2.2.0.37:9080                 HEALTHY     OK                outbound|9080||reviews-v2.bookinfo.svc.cluster.local
    2.2.0.37:9080                 HEALTHY     OK                outbound|9080||reviews.bookinfo.svc.cluster.local
    2.2.0.39:9080                 HEALTHY     OK                outbound|9080||reviews-v3.bookinfo.svc.cluster.local
    2.2.0.39:9080                 HEALTHY     OK                outbound|9080||reviews.bookinfo.svc.cluster.local
    ```
