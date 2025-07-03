# POC: Overriding global Istio AuthorizationPolicy from application namespace

This guide demonstrates how to verify that a global `allow-nothing` Istio `AuthorizationPolicy` defined
in the `istio-system` namespace can be overridden by a namespace-specific policy.

We use two sample workloads:
- `httpbin` in `ns-httpbin`
- `sleep` in `ns-sleep`

## Objective

- Deny all traffic globally using a policy in `istio-system`
- Allow only traffic from `ns-sleep` to `httpbin.ns-httpbin`
- Verify behavior before and after applying the namespace-scoped AuthorizationPolicy

## Steps

### 1. Create two namespaces and enable Istio injection

```bash
kubectl create ns ns-httpbin
kubectl create ns ns-sleep

kubectl label ns ns-httpbin istio-injection=enabled
kubectl label ns ns-sleep istio-injection=enabled
```

### 2. Deploy httpbin in the `ns-httpbin` namespace

```bash
kubectl apply -n ns-httpbin -f ../sample-yamls-ambient/httpbin.yaml
```

### 3. Deploy sleep in the `ns-sleep` namespace

```bash
kubectl apply -n ns-sleep -f ../sample-yamls-ambient/sleep.yaml
```

### 4. Apply global `allow-nothing` AuthorizationPolicy

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-nothing
  namespace: istio-system
spec: {}
EOF
```

### 5. Verify that requests from sleep to httpbin are denied

```bash
sleep_pod_name=$(kubectl get pods -n ns-sleep -l app=sleep -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ns-sleep "$sleep_pod_name" -- curl -s -o /dev/null -w "%{http_code}" http://httpbin.ns-httpbin.svc.cluster.local:8000/get
# Expected output: 403 (RBAC: access denied)
```

### 6. Create an AuthorizationPolicy to allow traffic from ns-sleep to httpbin

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-sleep
  namespace: ns-httpbin
spec:
  selector:
    matchLabels:
      app: httpbin
  rules:
  - from:
    - source:
        namespaces: ["ns-sleep"]
EOF
```

### 7. Verify that requests from sleep to httpbin are now allowed.

```bash
kubectl exec -n ns-sleep "$sleep_pod_name" -- curl -s -o /dev/null -w "%{http_code}" http://httpbin.ns-httpbin.svc.cluster.local:8000/get
# Expected output: 200
```
