## User Defined Networks (UDN) in OpenShift using Sail Operator

The implementation of User Defined Networks (UDNs) allows for the creation of multiple isolated networks, moving beyond the
limitation of a single default network for all pods. UDN support is added as part of OVN-Kubernetes in order for the OpenShift
networking solution to be more pluggable, flexible, and modular to cater to customer needs.

### Single Control Plane mode

| | L3 CUDN Network | L2 CUDN Network |
|---|---|---|
| Sidecar mode | [L3 CUDN with Sidecar](./L3CUDNs_Sidecar_Readme.md) | [L2 CUDN with Sidecar](./L2CUDNs_Sidecar_Readme.md) |
| Ambient mode | [L3 CUDN with Ambient](./L3CUDNs_Ambient_Readme.md) | [L2 CUDN with Ambient](./L2CUDNs_Ambient_Readme.md) |
