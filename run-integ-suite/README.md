# To execute Istio integration tests on an OCP cluster

After deploying the OCP cluster, export the KUBECONFIG on the shell to point to the OCP Cluster.

```shell
export HUB="gcr.io/istio-testing"
export TAG="latest"
export TEST_OUTPUT_FORMAT="junit"
export TEST_SUITE="pilot"
```

The first argument is the testsuite to run. Default is "pilot". Available options are "pilot", "security", "telemetry", "helm".
The second argument is the list of tests to be skipped.
```shell
$ bash integ-suite-ocp.sh $TEST_SUITE 'TestGatewayConformance|TestCustomGateway|TestCNIRaceRepair|TestGateway/managed-owner|TestProxyHeaders|TestCustomGateway/helm|TestCustomGateway/helm-simple|TestTcpProbe/rewrite-success|TestGRPCProbe|TestTunnelingOutboundTraffic|TestCNIVersionSkew|TestGateway|TestIngress|TestTraffic/jwt-claim-route|TestLabelChanges|TestLocality|TestMirroring/mirror-percent-absent|TestMirroring/mirror-50|TestMirroring/mirror-10|TestMirroringExternalService|TestTraffic/virtualservice|TestTraffic/serverfirst/tcp-server|TestTraffic/loop|TestTraffic/tls-origination|TestTraffic/externalname|TestTraffic/host|TestTraffic/envoyfilter|TestTraffic/consistent-hash|TestTraffic/externalservice|TestTraffic/upstreamproxy|TestTraffic/gateway/404|TestTraffic/gateway/https_redirect|TestTraffic/gateway/https_with_x-forwarded-proto|TestTraffic/gateway/cipher_suite|TestTraffic/gateway/optional_mTLS|TestTraffic/gateway/http_redirect_when_vs_port_specify_https|TestTraffic/gateway/http_return_400_with_with_x-forwarded-proto_https_when_vs_port_specify_https|TestTraffic/gateway/client_protocol'
```

To execute tests with dualStack mode, use the following command.
```shell
$ bash integ-suite-ocp-dual.sh $TEST_SUITE 'TestGatewayConformance|TestCustomGateway|TestCNIRaceRepair|TestGateway/managed-owner|TestProxyHeaders|TestCustomGateway/helm|TestCustomGateway/helm-simple|TestTcpProbe/rewrite-success|TestGRPCProbe|TestTunnelingOutboundTraffic|TestCNIVersionSkew|TestGateway|TestIngress|TestTraffic/jwt-claim-route|TestLabelChanges|TestLocality|TestMirroring/mirror-percent-absent|TestMirroring/mirror-50|TestMirroring/mirror-10|TestMirroringExternalService|TestTraffic/virtualservice|TestTraffic/serverfirst/tcp-server|TestTraffic/loop|TestTraffic/tls-origination|TestTraffic/externalname|TestTraffic/host|TestTraffic/envoyfilter|TestTraffic/consistent-hash|TestTraffic/externalservice|TestTraffic/upstreamproxy|TestTraffic/gateway/404|TestTraffic/gateway/https_redirect|TestTraffic/gateway/https_with_x-forwarded-proto|TestTraffic/gateway/cipher_suite|TestTraffic/gateway/optional_mTLS|TestTraffic/gateway/http_redirect_when_vs_port_specify_https|TestTraffic/gateway/http_return_400_with_with_x-forwarded-proto_https_when_vs_port_specify_https|TestTraffic/gateway/client_protocol'
```