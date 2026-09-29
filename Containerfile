# =============================================================================
# Containerfile -- custom must-gather image for Prometheus TSDB extraction
#
# Base: registry.redhat.io/openshift4/ose-must-gather:latest
#
#   - THE official OpenShift must-gather payload image: ships the matching
#     'oc' client, the stock collection-scripts tree under /usr/bin
#     (gather_monitoring, gather_etcd, ...), plus jq/curl/tar on RHEL.
#     Our custom /usr/bin/gather REPLACES the stock entrypoint - that is
#     exactly how custom payloads work with
#       oc adm must-gather --image <custom>
#
#   - 'openshift4/ose-cli:4.22' does NOT exist in registry.redhat.io:
#     the repo's tag listing carries only legacy 4.1/4.2/4.3 tags, and
#     modern releases (4.18+) ship the must-gather payload separately as
#     ose-must-gather. (Verified against registry.redhat.io tag API on
#     2026-09-25.)
#
#   - Auth: registry.redhat.io needs a customer-portal token:
#       podman pull --authfile ~/.docker/config.json \
#           registry.redhat.io/openshift4/ose-must-gather:latest
#     or  podman login registry.redhat.io
#
# NOTE: no ENTRYPOINT instruction - the framework pod spec invokes
# /usr/bin/gather directly (init container); a copy sidecar then rsyncs
# /must-gather back out. Adding an ENTRYPOINT breaks custom payloads.
#
# KUBECONFIG INJECTION CONTRACT (see ../run-must-gather.sh)
#   The image is auth-agnostic on purpose: it ships NO credentials.
#   run-must-gather.sh creates a Secret from the operator's local
#   kubeconfig and appends a volume + volumeMount to the init-container
#   spec so the file appears at:
#       /etc/must-gather-kubeconfig/kubeconfig
#   /usr/bin/gather then does `export KUBECONFIG=<that path>` and uses it
#   for every oc/curl call (falling back to the framework's built-in
#   cluster-admin SA token when the mount is absent).
#   The secret is deleted again after the run.
# =============================================================================
FROM registry.redhat.io/openshift4/ose-must-gather:latest

# Apply available UBI-8 security/bug fixes (expat, libxml2, tar, coreutils,
# gawk, gdbserver, libgcc/libstdc++, bind, ...). The UBI-8 public repos carry
# these as regular updates, not 'security', so use a plain update.
# Also drop the subscription-manager stack: the payload never registers or
# consumes entitlements in-cluster, and the subman packages carry many
# unfixable CVEs (python3-syspurpose, rhsm-certificates, cloud-what, ...).
# 'oc', dnf, tar and rsync all keep working after the removal (verified).
RUN dnf -y update \
    && dnf -y remove subscription-manager dnf-plugin-subscription-manager \
           python3-syspurpose python3-cloud-what \
           subscription-manager-rhsm-certificates \
           python3-subscription-manager-rhsm \
    && rm -rf /var/cache/dnf /var/cache/yum

# Custom entrypoint: pre-flight -> TSDB snapshot (Prometheus Admin API,
# with crash-consistent direct-copy fallback) -> oc cp extraction ->
# remote cleanup. Stock gather_* helpers remain in the image if future
# variants want to chain them.
# --chmod keeps it a single layer (COPY already carries the executable bit;
# a follow-up RUN chmod is a no-op and produced a duplicated layer entry).
COPY --chmod=0755 gather /usr/bin/gather
