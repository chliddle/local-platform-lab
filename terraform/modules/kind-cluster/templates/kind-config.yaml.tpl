kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${cluster_name}
# kube-scheduler/kube-controller-manager's default leader-election timing
# (10s renew deadline, ultimately a ~5s per-attempt request timeout to the
# API server) is tuned for real multi-node HA clusters, where losing
# leadership fast matters. Confirmed live, repeatedly, across all three
# clusters: on this single-control-plane lab, sharing one Docker Desktop
# VM with two other equally-heavy clusters, the API server can legitimately
# take longer than 5s to respond during a reconcile storm -- and when it
# does, these components give up the lease and crash-loop even though
# nothing is actually broken (there's only one candidate; there's no HA
# failover being protected by failing fast). Loosened well beyond what a
# real production cluster would ever want, since single-node means there's
# no multi-node race to guard against.
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    scheduler:
      extraArgs:
        leader-elect-lease-duration: "60s"
        leader-elect-renew-deadline: "45s"
        leader-elect-retry-period: "5s"
    controllerManager:
      extraArgs:
        leader-elect-lease-duration: "60s"
        leader-elect-renew-deadline: "45s"
        leader-elect-retry-period: "5s"
nodes:
  - role: control-plane
    image: ${node_image}
