#!/usr/bin/env bash
# The storage spike (#91), never merged. tofu/tests/storage runs it on slot 1 of a cluster.yml run with spike set, once
# the cluster is ready, with VIP, CANDIDATE (linstor, rook-ceph or longhorn) and NODES in the environment.
# Prepares every node with spike/storage-node.sh and installs KubeVirt, then times the candidate's install and measures
# it. Each result goes to the job summary, also when a later one fails. Exits 1 if any measurement failed.
# Single-quoted strings are scripts that run in pods and on nodes.
# shellcheck disable=SC2016
set -euo pipefail
shopt -s inherit_errexit

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
vip=${VIP:?}
# shellcheck source=/dev/null
source "$here/../tofu/tests/lib.sh" storage "$vip"
candidate=${CANDIDATE:?}
nodes=${NODES:?}

longhorn_v=v1.13.0
rook_v=v1.20.8
piraeus_v=v2.12.0
kubevirt_v=v1.9.0
raw=https://raw.githubusercontent.com
debian=docker.io/library/debian:trixie-slim
cirros=quay.io/kubevirt/cirros-container-disk-demo:$kubevirt_v
case $candidate in
  longhorn) ns=longhorn-system version=$longhorn_v ;;
  rook-ceph) ns=rook-ceph version=$rook_v ;;
  linstor) ns=piraeus-datastore version=$piraeus_v ;;
  *) echo "unknown candidate $candidate" >&2; exit 2 ;;
esac

work=$(mktemp -d)
export KUBECONFIG=$work/kubeconfig
failures=0
k() { kubectl "$@"; }

# Results go to files that report renders into the job summary on exit.
row() {
  log "$1: $2"
  printf '| %s | %s |\n' "$1" "$2" >>"$work/rows"
}
failed() {
  row "$1" "FAILED: $2"
  failures=$((failures + 1))
  diagnose "$1"
}
note() { echo "- $*" >>"$work/notes"; }
diagnose() {
  {
    echo "<details><summary>State after: $1</summary>"
    echo
    echo '```'
    k get pods -A -o wide 2>&1 | grep -v -E ' Running | Completed ' | head -n 40 || :
    k get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -n 25 | cut -c 1-300 || :
    if [[ $candidate == linstor ]]; then
      k -n "$ns" logs -l app.kubernetes.io/component=linstor-satellite -c drbd-module-loader --tail=15 2>&1 | head -n 40 || :
    fi
    echo '```'
    echo "</details>"
    echo
  } >>"$work/diag"
}
report() {
  {
    echo "## Storage spike: $candidate $version on $nodes nodes"
    echo
    cat "$work/notes" 2>/dev/null || :
    echo
    echo "| Measurement | Result |"
    echo "|---|---|"
    cat "$work/rows" 2>/dev/null || :
    echo
    cat "$work/resources" 2>/dev/null || :
    echo
    cat "$work/diag" 2>/dev/null || :
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
trap report EXIT

# Applies stdin, retrying for 5 minutes while the CRDs and webhooks it needs come up.
apply_until() {
  local f=$work/apply.yaml i
  cat >"$f"
  for ((i = 0; i < 150; i++)); do
    k apply --server-side --force-conflicts -f "$f" >/dev/null 2>"$work/apply.err" && return 0
    sleep 2
  done
  cat "$work/apply.err" >&2
  return 1
}

# sc <name> <provisioner> <key=value>...
sc() {
  local kv
  printf -- '---\napiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata:\n  name: %s\nprovisioner: %s\n' "$1" "$2"
  printf 'volumeBindingMode: WaitForFirstConsumer\nallowVolumeExpansion: true\nparameters:\n'
  for kv in "${@:3}"; do
    printf '  %s: "%s"\n' "${kv%%=*}" "${kv#*=}"
  done
}

# pvc <name> <class> <size> <access mode> [volume mode]
pvc() {
  cat <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $1
spec:
  storageClassName: $2
  accessModes: [$4]
  volumeMode: ${5:-Filesystem}
  resources:
    requests:
      storage: $3
EOF
}

# pod_spec <claim> <script> [node] prints a pod spec, indented to sit under a pod's or a pod template's spec:. The pod
# mounts the claim at /data and 256 MiB of RAM at /buf, and sees its node's name as NODE.
pod_spec() {
  cat <<EOF
restartPolicy: ${restart:-Never}
nodeSelector: {${3:+kubernetes.io/hostname: $3}}
terminationGracePeriodSeconds: 1
containers:
  - name: c
    image: $debian
    command: ["bash", "-c", $(jq --raw-input --slurp . <<<"$2")]
    env:
      - name: NODE
        valueFrom:
          fieldRef:
            fieldPath: spec.nodeName
    volumeMounts:
      - {name: d, mountPath: /data}
      - {name: buf, mountPath: /buf}
volumes:
  - {name: d, persistentVolumeClaim: {claimName: $1}}
  - {name: buf, emptyDir: {medium: Memory, sizeLimit: 300Mi}}
EOF
}

# pod <name> <claim> <script> [node]
pod() {
  printf -- '---\napiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\nspec:\n' "$1"
  pod_spec "$2" "$3" "${4:-}" | sed 's/^/  /'
}

# Sums kubectl top over the candidate's namespace per node: "<node> <millicores> <MiB>".
sample() {
  local top i
  for i in 1 2 3 4 5 6; do
    if top=$(k top pod -n "$ns" --no-headers 2>/dev/null) && [[ -n $top ]]; then
      LC_ALL=C join \
        <(k get pod -n "$ns" --no-headers -o custom-columns=N:.metadata.name,NODE:.spec.nodeName | LC_ALL=C sort) \
        <(LC_ALL=C sort <<<"$top") |
        awk '{cpu[$2] += $3; mem[$2] += $4} END {for (n in cpu) print n, cpu[n], mem[n]}'
      return 0
    fi
    sleep 10
  done
  return 1
}

# Slot 1's Tailscale path to every peer of this run, right now.
paths() {
  tailscale status --json | jq --raw-output '.Self.UserID as $me | [.Peer // {} | .[] | select(.UserID == $me)
    | "slot \(.HostName | sub(".*-"; "")) \(if (.CurAddr // "") != "" then "direct" else "DERP \(.Relay)" end)"]
    | sort | join(", ")'
}

candidate_images() {
  case $candidate in
    longhorn) curl -fsSL "$raw/longhorn/longhorn/$longhorn_v/deploy/longhorn-images.txt" | sed 's|^|docker.io/|' ;;
    rook-ceph) curl -fsSL "$raw/rook/rook/$rook_v/deploy/examples/images.txt" ;;
    linstor)
      echo "quay.io/piraeusdatastore/piraeus-operator:$piraeus_v"
      # Every component's image, and the DRBD module loader that the operator picks for Rocky Linux 10.
      for f in 0_piraeus_datastore_images.yaml 0_sig_storage_images.yaml; do
        curl -fsSL "$raw/piraeusdatastore/piraeus-operator/$piraeus_v/config/manager/$f"
      done | awk '/^base:/ {b = $2} /^    tag:/ {t = $2} /^    image:/ && !/#/ {print b "/" $2 ":" t}
        /^        image: drbd9-almalinux10$/ {print b "/" $2 ":" t}'
      ;;
  esac
}

install_longhorn() {
  k apply --server-side --force-conflicts -f "$raw/longhorn/longhorn/$longhorn_v/deploy/longhorn.yaml" >/dev/null || return 1
  local p=(staleReplicaTimeout=30 dataEngine=v1)
  {
    sc spike-r1 driver.longhorn.io numberOfReplicas=1 "${p[@]}"
    sc spike-r3 driver.longhorn.io numberOfReplicas=3 "${p[@]}"
    sc spike-rwx driver.longhorn.io numberOfReplicas=3 "${p[@]}"
    sc spike-block driver.longhorn.io numberOfReplicas=3 migratable=true "${p[@]}"
  } | apply_until
}

install_rook-ceph() {
  local ex=$raw/rook/rook/$rook_v/deploy/examples s=csi.storage.k8s.io
  k apply --server-side --force-conflicts -f "$ex/crds.yaml" -f "$ex/common.yaml" -f "$ex/csi-operator.yaml" \
    >/dev/null || return 1
  local rbd=(clusterID=rook-ceph imageFormat=2 imageFeatures=layering "$s/fstype=ext4"
    "$s/provisioner-secret-name=rook-csi-rbd-provisioner" "$s/provisioner-secret-namespace=rook-ceph"
    "$s/controller-expand-secret-name=rook-csi-rbd-provisioner" "$s/controller-expand-secret-namespace=rook-ceph"
    "$s/controller-publish-secret-name=rook-csi-rbd-provisioner" "$s/controller-publish-secret-namespace=rook-ceph"
    "$s/node-stage-secret-name=rook-csi-rbd-node" "$s/node-stage-secret-namespace=rook-ceph")
  local cephfs=(clusterID=rook-ceph fsName=spike-fs pool=spike-fs-data
    "$s/provisioner-secret-name=rook-csi-cephfs-provisioner" "$s/provisioner-secret-namespace=rook-ceph"
    "$s/controller-expand-secret-name=rook-csi-cephfs-provisioner" "$s/controller-expand-secret-namespace=rook-ceph"
    "$s/controller-publish-secret-name=rook-csi-cephfs-provisioner" "$s/controller-publish-secret-namespace=rook-ceph"
    "$s/node-stage-secret-name=rook-csi-cephfs-node" "$s/node-stage-secret-namespace=rook-ceph")
  {
    # operator.yaml holds CSI operator resources whose CRDs csi-operator.yaml only just created.
    curl -fsSL "$ex/operator.yaml"
    echo "---"
    # From deploy/examples/cluster.yaml: AES CSI keys, since Rocky 10's kernel predates 7.0. One mgr, no dashboard.
    cat <<EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: $ceph_image
  dataDirHostPath: /var/lib/rook
  security:
    cephx:
      csi:
        keyType: aes
  mon:
    count: 3
  mgr:
    count: 1
  dashboard:
    enabled: false
  crashCollector:
    disable: true
  cephConfig:
    global:
      mon_allow_pool_size_one: "true"
  storage:
    useAllNodes: true
    useAllDevices: false
    devices:
      - name: vdb
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: spike-r3
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: spike-r1
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 1
    requireSafeReplicaSize: false
---
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: spike-fs
  namespace: rook-ceph
spec:
  metadataPool:
    replicated:
      size: 3
  dataPools:
    - name: data
      replicated:
        size: 3
  metadataServer:
    activeCount: 1
    activeStandby: true
---
apiVersion: ceph.rook.io/v1
kind: CephFilesystemSubVolumeGroup
metadata:
  name: spike-fs-csi
  namespace: rook-ceph
spec:
  name: csi
  filesystemName: spike-fs
EOF
    sc spike-r1 rook-ceph.rbd.csi.ceph.com pool=spike-r1 "${rbd[@]}"
    sc spike-r3 rook-ceph.rbd.csi.ceph.com pool=spike-r3 "${rbd[@]}"
    sc spike-block rook-ceph.rbd.csi.ceph.com pool=spike-r3 "${rbd[@]}"
    sc spike-rwx rook-ceph.cephfs.csi.ceph.com "${cephfs[@]}"
  } | apply_until
}

install_linstor() {
  k apply --server-side --force-conflicts \
    -f "https://github.com/piraeusdatastore/piraeus-operator/releases/download/$piraeus_v/manifest.yaml" >/dev/null ||
    return 1
  local l=linstor.csi.linbit.com
  {
    cat <<'EOF'
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstorcluster
spec: {}
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: storage-pool
spec:
  storagePools:
    - name: pool1
      lvmThinPool: {}
      source:
        hostDevices:
          - /dev/vdb
EOF
    sc spike-r1 $l "$l/storagePool=pool1" "$l/placementCount=1"
    sc spike-r3 $l "$l/storagePool=pool1" "$l/placementCount=3"
    sc spike-rwx $l "$l/storagePool=pool1" "$l/placementCount=3"
    sc spike-block $l "$l/storagePool=pool1" "$l/placementCount=3"
  } | apply_until
}

install_kubevirt() {
  k apply --server-side --force-conflicts \
    -f "https://github.com/kubevirt/kubevirt/releases/download/$kubevirt_v/kubevirt-operator.yaml" >/dev/null || return 1
  k wait crd/kubevirts.kubevirt.io --for condition=Established --timeout=2m >/dev/null || return 1
  # Software emulation: a VM in a node is a third level of nesting.
  apply_until <<'EOF' || return 1
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  imagePullPolicy: IfNotPresent
  configuration:
    developerConfiguration:
      useEmulation: true
EOF
  k -n kubevirt wait kv/kubevirt --for condition=Available --timeout=10m >/dev/null
}

# The node killed is never slot 1's, which runs this, nor the VIP holder, which serves the API.
failover() {
  local holder victim="" s t_kill back="" where="" p off writes gap name
  holder=$(vip_ssh hostname)
  for ((s = nodes; s > 1; s--)); do
    if [[ -n ${node_at[$s]:-} && ${node_at[$s]} != "$holder" ]]; then
      victim=${node_at[$s]}
      break
    fi
  done
  [[ -n $victim ]] || { failed "Storage node killed" "no node besides slot 1 and the VIP holder"; return; }
  local writer='while :; do
  if echo "$(date +%s.%N) $NODE" | dd of=/data/log oflag=append conv=notrunc,fsync status=none; then
    echo "W $(date +%s.%N) $NODE"
  fi
  sleep 0.5
done'
  # The victim's writer is a Deployment, so it is recreated on another node. Only the victim is schedulable while it
  # starts. It tolerates a not-ready or unreachable node for 10 s instead of 300 s, so the time measured is the
  # storage's rather than the eviction's.
  { pvc fo-survivor spike-r3 1Gi ReadWriteOnce; pod fo-survivor fo-survivor "$writer" "$me"; } | k apply -f - >/dev/null
  SECONDS=0
  until k logs fo-survivor 2>/dev/null | grep -q '^W'; do
    ((SECONDS < 600)) || { failed "Storage node killed" "slot 1's writer did not start in 10 min"; return; }
    sleep 3
  done
  for name in "${!ip_of[@]}"; do
    [[ $name == "$victim" ]] || k cordon "$name" >/dev/null
  done
  {
    pvc fo-victim spike-r3 1Gi ReadWriteOnce
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fo-victim
spec:
  replicas: 1
  selector:
    matchLabels: {app: fo-victim}
  template:
    metadata:
      labels: {app: fo-victim}
    spec:
      tolerations:
        - {key: node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 10}
        - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 10}
$(restart=Always pod_spec fo-victim "$writer" | sed 's/^/      /')
EOF
  } | k apply -f - >/dev/null
  SECONDS=0
  until k logs deploy/fo-victim 2>/dev/null | grep -q '^W'; do
    if ((SECONDS > 600)); then
      for name in "${!ip_of[@]}"; do k uncordon "$name" >/dev/null; done
      failed "Storage node killed" "the killed node's writer did not start in 10 min"
      return
    fi
    sleep 3
  done
  for name in "${!ip_of[@]}"; do k uncordon "$name" >/dev/null; done
  # The node's clock minus this runner's, to place the survivor's write times.
  off=$(awk -v r="$EPOCHREALTIME" -v n="$(node_ssh "${ip_of[$me]}" date +%s.%N)" 'BEGIN {printf "%.3f", n - r}')
  log "powering off $victim (slot ${slot_of[$victim]})"
  t_kill=$EPOCHREALTIME
  # A powered-off peer never closes the connection, so the ssh runs into its timeout.
  (node_ssh "${ip_of[$victim]}" 'sudo systemctl poweroff --force --force' </dev/null || :) &
  while [[ -z $back ]] && ((EPOCHSECONDS - ${t_kill%.*} < 720)); do
    for p in $(k get pods -l app=fo-victim -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName}{"\n"}{end}'); do
      if [[ -n ${p#*=} && ${p#*=} != "$victim" ]] && k logs "${p%=*}" 2>/dev/null | grep -q '^W'; then
        back=$((EPOCHSECONDS - ${t_kill%.*}))
        where=${p#*=}
      fi
    done
    sleep 3
  done
  # The survivor's writes from 5 s before the kill to 180 s after.
  while ((EPOCHSECONDS - ${t_kill%.*} < 185)); do sleep 5; done
  read -r writes gap < <(k logs fo-survivor | awk -v t="$t_kill" -v off="$off" '$1 == "W" {
    ts = $2 - off
    if (ts >= t - 5 && ts <= t + 180) { if (prev != "" && ts - prev > max) max = ts - prev; prev = ts; n++ } }
    END {printf "%d %.1f\n", n, max}')
  local io="I/O on slot 1's 3-replica volume: $writes writes in the 185 s around the kill, longest gap ${gap} s."
  if [[ -n $back ]]; then
    row "Storage node killed (slot ${slot_of[$victim]})" \
      "$io The killed node's pod wrote again on slot ${slot_of[$where]} after ${back} s."
  else
    failed "Storage node killed (slot ${slot_of[$victim]})" "$io The killed node's pod had not written again after 12 min."
  fi
}

# Denials since prep on every node, by command.
avc() {
  local name out
  for name in "${!ip_of[@]}"; do
    out=$(node_ssh "${ip_of[$name]}" sudo bash -s -- "$since" <<'EOF'
awk -v t="$1" 'match($0, /audit\(([0-9]+)/, m) && m[1] >= t && /avc: +denied/' /var/log/audit/audit.log |
  grep -o 'comm="[^"]*"' | sort | uniq -c | sort -rn | head -n 5 | awk '{printf "%s%s x%s", s, $2, $1; s = ", "}'
EOF
    ) || out="unreadable"
    echo "slot ${slot_of[$name]}: ${out:-none}"
  done | sort | paste -sd ';' | sed 's/;/; /g'
}

log "fetching the kubeconfig from $vip"
vip_ssh 'sudo cat /etc/rancher/rke2/rke2.yaml' | sed "s/127.0.0.1/$vip/" >"$KUBECONFIG"
k version 2>&1 || :

declare -A ip_of slot_of node_at
while read -r name addr; do
  s=$(node_ssh "$addr" 'cat /sys/class/net/*/address' </dev/null | sed -n 's/^52:54:00:c1:00:0\([1-9]\)$/\1/p' | head -n 1)
  ip_of[$name]=$addr slot_of[$name]=$s node_at[$s]=$name
done < <(k get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
me=${node_at[1]:?no node with slot 1\'s MAC}
log "nodes: $(for n in "${!slot_of[@]}"; do echo "slot ${slot_of[$n]} $n ${ip_of[$n]}"; done | sort | paste -sd ',')"

selinux=$(node_ssh "${ip_of[$me]}" getenforce)
sb=$(node_ssh "${ip_of[$me]}" 'od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-* | awk "{print \$NF}"')
note "Nodes: 4 vCPU, ${TF_VAR_memory_mib:-4096} MiB, a ${TF_VAR_data_disk_gib:-0} GiB data disk (vdb, qcow2 with \
cache=unsafe on the runner's disk), Secure Boot $([[ $sb == 1 ]] && echo on || echo off), SELinux $selinux. \
KubeVirt $kubevirt_v with software emulation. Upstream manifests and defaults."

# Preparation, untimed.
log "preparing every node"
since=$EPOCHSECONDS
curl -fsSL "$raw/rook/rook/$rook_v/deploy/examples/images.txt" >"$work/rook-images"
ceph_image=$(grep -m 1 '^quay.io/ceph/ceph:' "$work/rook-images")
mapfile -t images < <({
  candidate_images
  printf '%s\n' "quay.io/kubevirt/virt-"{operator,api,controller,handler,launcher}":$kubevirt_v" "$cirros" "$debian"
} | sort -u)
declare -A pids
for name in "${!ip_of[@]}"; do
  ssh_timeout=1800 node_ssh "${ip_of[$name]}" sudo bash -s -- "$candidate" "${images[@]}" \
    <"$here/storage-node.sh" >"$work/prep-$name" 2>&1 &
  pids[$name]=$!
done
for name in "${!pids[@]}"; do
  if ! wait "${pids[$name]}"; then
    cat "$work/prep-$name"
    failed "Node prep" "slot ${slot_of[$name]}: $(tail -n 3 "$work/prep-$name" | paste -sd ' ')"
    exit 1
  fi
  cat "$work/prep-$name"
  grep -q 'could not pull' "$work/prep-$name" && note "$(grep 'could not pull' "$work/prep-$name" | paste -sd ' ')"
done
note "Prep took $((EPOCHSECONDS - since)) s: host packages and every image on every node ($(grep -h 'in [0-9]*s' \
  "$work"/prep-* | sort | paste -sd ' ' | sed 's/ slot/, slot/g'))."

log "installing KubeVirt"
SECONDS=0
if install_kubevirt; then
  kubevirt=yes
  log "KubeVirt available after ${SECONDS}s"
else
  kubevirt=""
  failed "KubeVirt install" "not Available after ${SECONDS} s"
fi

# Timed: from the first apply to a pod's 1 MiB fsync'd write to a new 3-replica PVC. A new PVC and pod every 15 s, so
# no attempt waits out the CSI provisioner's back-off.
log "installing $candidate"
t0=$EPOCHSECONDS
if ! "install_$candidate"; then
  failed "Install" "kubectl apply failed after $((EPOCHSECONDS - t0)) s: $(tail -n 3 "$work/apply.err" 2>/dev/null)"
  exit 1
fi
log "applied after $((EPOCHSECONDS - t0))s, waiting for a writable 3-replica PVC"
n=0 next=0 ok=""
while ((EPOCHSECONDS - t0 < 1500)); do
  ok=$(k get pods -o jsonpath='{range .items[?(@.status.phase=="Succeeded")]}{.metadata.name}{"\n"}{end}' |
    grep -m 1 '^first-' || :)
  [[ -z $ok ]] || break
  if ((EPOCHSECONDS >= next)); then
    n=$((n + 1))
    { pvc "first-$n" spike-r3 1Gi ReadWriteOnce
      pod "first-$n" "first-$n" 'dd if=/dev/urandom of=/data/f bs=1M count=1 conv=fsync'; } | k apply -f - >/dev/null || :
    next=$((EPOCHSECONDS + 15))
  fi
  sleep 2
done
elapsed=$((EPOCHSECONDS - t0))
mapfile -t pulled < <(k get events -A --field-selector reason=Pulling -o json | jq --raw-output --argjson t0 "$t0" '
  .items[] | select(((.lastTimestamp // .eventTime // .firstTimestamp // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $t0)
  | .message' | sort -u)
pulls="image pulls during the timing: ${pulled[*]:-none}"
if [[ $candidate == linstor ]]; then
  pulls+=". DRBD module built and loaded at boot by $(k -n "$ns" get pods -o json | jq --raw-output '
    [.items[].status.initContainerStatuses[]? | select(.name == "drbd-module-loader") | .state.terminated // empty
      | (.finishedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)]
    | "\(length) loaders, the slowest in \(max // "n/a") s"')"
fi
if [[ -z $ok ]]; then
  failed "Install start to the first bound, writable 3-replica PVC" "none after ${elapsed} s and $n attempts; $pulls"
  exit 1
fi
row "Install start to the first bound, writable 3-replica PVC" "${elapsed} s ($ok of $n); $pulls"
mapfile -t attempts < <(seq -f 'first-%g' 1 "$n")
k delete pod,pvc --ignore-not-found --wait=false "${attempts[@]}" >/dev/null

log "settling for 60s before the idle sample"
sleep 60
sample >"$work/idle" || :

ingest='head -c 256M /dev/urandom >/buf/r
echo START
n=0 start=$(date +%s.%N) end=$((SECONDS + 60))
while ((SECONDS < end)); do
  dd if=/buf/r of=/data/f bs=4M count=16 oflag=direct conv=notrunc seek=$((n % 48 * 16)) status=none
  n=$((n + 1))
done
echo "RESULT $n $start $(date +%s.%N)"'
for ((s = 2; s <= nodes; s++)); do
  [[ -n ${node_at[$s]:-} ]] || continue
  node_ssh "${ip_of[${node_at[$s]}]}" 'iperf3 --server --one-off --daemon' </dev/null
  sleep 1
  row "TCP from slot 1's node to slot $s's, iperf3 for 10 s on the node network" "$(ssh_timeout=60 node_ssh \
    "${ip_of[$me]}" "iperf3 --client ${ip_of[${node_at[$s]}]} --time 10 --json" </dev/null |
    jq --raw-output '"\(.end.sum_received.bits_per_second / 8388608 | floor) MiB/s"' || echo failed)"
done
note "MTU on slot 1's node: NIC ${TF_VAR_mtu:-unset}, flannel.1 and pod veths $(node_ssh "${ip_of[$me]}" \
  'cat /sys/class/net/flannel.1/mtu /sys/class/net/cali*/mtu 2>/dev/null' </dev/null | sort -u | paste -sd /)."
for r in 1 3; do
  name=ingest-r$r
  log "ingest into a $r-replica volume"
  { pvc "$name" "spike-r$r" 4Gi ReadWriteOnce; pod "$name" "$name" "$ingest" "$me"; } | k apply -f - >/dev/null
  SECONDS=0
  until k logs "$name" 2>/dev/null | grep -q '^START'; do
    ((SECONDS < 600)) || break
    sleep 3
  done
  if ((r == 3)); then
    sleep 40
    sample >"$work/ingest" || :
  fi
  if k wait "pod/$name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m >/dev/null 2>&1 &&
    line=$(k logs "$name" | grep '^RESULT'); then
    row "Ingest, $r replica" "$(awk '{printf "%.0f MiB/s over %.0f s", $2 * 64 / ($4 - $3), $4 - $3}' <<<"$line"), \
writer on slot 1. Slot 1's tailnet paths: $(paths)"
  else
    failed "Ingest, $r replica" "the writer did not finish ($(k get pod "$name" -o jsonpath='{.status.phase}'))"
  fi
  k delete pod "$name" --wait=false >/dev/null
done

log "RWX filesystem on two nodes"
other=${node_at[2]:?no slot 2}
both='echo "$NODE" >"/data/$NODE"
until (($(ls /data | grep -c '^node-') >= 2)); do sleep 1; done
echo "BOTH $(ls /data | grep '^node-' | paste -sd " ")"
sleep infinity'
{ pvc rwx spike-rwx 1Gi ReadWriteMany; pod rwx-a rwx "$both" "$me"; pod rwx-b rwx "$both" "$other"; } | k apply -f - >/dev/null
SECONDS=0
until k logs rwx-a 2>/dev/null | grep -q '^BOTH' && k logs rwx-b 2>/dev/null | grep -q '^BOTH'; do
  ((SECONDS < 600)) || break
  sleep 3
done
if ((SECONDS < 600)); then
  row "RWX filesystem mounted on two nodes" "pods on slots 1 and 2 each read the other's file ${SECONDS} s after the PVC"
else
  failed "RWX filesystem mounted on two nodes" "the pods did not both see both files in 10 min"
fi
k delete pod rwx-a rwx-b --wait=false >/dev/null

if [[ -n $kubevirt ]]; then
  log "KubeVirt live migration"
  {
    pvc vm-disk spike-block 1Gi ReadWriteMany Block
    cat <<EOF
---
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstance
metadata:
  name: vm1
spec:
  domain:
    devices:
      # Bridge binding on the pod network blocks live migration, so no network.
      autoattachPodInterface: false
      disks:
        - {name: boot, disk: {bus: virtio}}
        - {name: data, disk: {bus: virtio}}
    resources:
      requests:
        memory: 256Mi
  volumes:
    - {name: boot, containerDisk: {image: $cirros}}
    - {name: data, persistentVolumeClaim: {claimName: vm-disk}}
EOF
  } | k apply -f - >/dev/null
  if k wait vmi/vm1 --for=jsonpath='{.status.phase}'=Running --timeout=10m >/dev/null 2>&1; then
    from=$(k get vmi vm1 -o jsonpath='{.status.nodeName}')
    k apply -f - >/dev/null <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: mig1
spec:
  vmiName: vm1
EOF
    SECONDS=0
    phase=""
    until [[ $phase == Succeeded || $phase == Failed ]] || ((SECONDS > 600)); do
      sleep 3
      phase=$(k get vmim mig1 -o jsonpath='{.status.phase}')
    done
    to=$(k get vmi vm1 -o jsonpath='{.status.nodeName}')
    if [[ $phase == Succeeded && $to != "$from" ]]; then
      row "KubeVirt VM on an RWX block volume live-migrates" \
        "from slot ${slot_of[$from]} to slot ${slot_of[$to]}, ${SECONDS} s from the migration's creation"
    else
      failed "KubeVirt VM on an RWX block volume live-migrates" "phase ${phase:-none} after ${SECONDS} s: \
$(k get vmi vm1 -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].message}' 2>&1) \
$(k get vmim mig1 -o jsonpath='{.status.migrationState.failureReason}' 2>&1)"
    fi
  else
    failed "KubeVirt VM on an RWX block volume live-migrates" "the VM was not Running after 10 min"
  fi
fi

row "SELinux denials since prep" "$(avc)"

log "killing a storage node"
failover

{
  echo "Storage pods (namespace $ns) per node, summed from kubectl top. Kernel work (DRBD, krbd, iSCSI) is not counted."
  echo
  echo "| Node | Idle CPU | Idle RAM | CPU during 3-replica ingest | RAM during 3-replica ingest |"
  echo "|---|---|---|---|---|"
  for ((s = 1; s <= nodes; s++)); do
    name=${node_at[$s]:-}
    [[ -n $name ]] || continue
    echo "| slot $s | $(awk -v n="$name" '$1 == n {printf "%d m | %d MiB", $2, $3; f = 1} END {if (!f) print "n/a | n/a"}' \
      "$work/idle" 2>/dev/null) | $(awk -v n="$name" '$1 == n {printf "%d m | %d MiB", $2, $3; f = 1}
      END {if (!f) print "n/a | n/a"}' "$work/ingest" 2>/dev/null) |"
  done
} >"$work/resources"

note "Timing: from the first kubectl apply of $candidate to a pod's 1 MiB fsync'd write to a new 3-replica PVC. A new \
PVC and pod every 15 s, so no attempt waits out the provisioner's back-off. Every image was pulled on every node first."
note "Ingest: one pod on slot 1's node writes 64 MiB of random data at a time, in 4 MiB O_DIRECT writes one after \
another, in a loop for 60 s, over 3 GiB of a 4 GiB volume. WireGuard and VXLAN between GitHub runners bound it, so it compares candidates only."
note "Node kill: systemctl poweroff --force --force on a node that is neither slot 1 nor the VIP holder. Its writer \
tolerates a not-ready or unreachable node for 10 s, not 300 s."
((failures == 0))
