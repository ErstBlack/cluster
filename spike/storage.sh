#!/usr/bin/env bash
# The storage spike (#91), never merged. tofu/tests/storage runs it on slot 1 of a cluster.yml run with spike set, once
# the cluster is ready, with VIP, CANDIDATE (linstor, rook-ceph or longhorn) and NODES in the environment.
# Prepares every node with spike/storage-node.sh and installs KubeVirt, then times the candidate's install and measures
# it. Each result goes to the job summary, also when a later one fails, and to RUNNER_TEMP/storage-results.json, which
# spike/aggregate.py reads. Exits 1 if any measurement failed.
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
csiaddons_v=v0.14.0
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
mkdir "$work/m"
touch "$work/metrics" "$work/status"
export KUBECONFIG=$work/kubeconfig
failures=0
k() { kubectl "$@"; }

# Results go to files that report renders into the job summary and the results JSON on exit.
row() {
  log "$1: $2"
  printf '| %s | %s |\n' "$1" "$2" >>"$work/rows"
}
failed() {
  row "$1" "FAILED: $2"
  failures=$((failures + 1))
  diagnose "$1"
}
# A result that neither passes nor shows the candidate failing, such as a harness or configuration cause not yet ruled
# out. It does not fail the run.
inconclusive() {
  row "$1" "INCONCLUSIVE: $2"
  diagnose "$1"
}
note() { echo "- $*" >>"$work/notes"; }
# metric <key> <number> and status <key> <word> feed spike/aggregate.py. Anything but a number is left out.
metric() { [[ ! ${2:-} =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || echo "$1 $2" >>"$work/metrics"; }
status() { echo "$1 $2" >>"$work/status"; }
diagnose() {
  {
    echo "<details><summary>State after: $1</summary>"
    echo
    echo '```'
    k get pods -A -o wide 2>&1 | grep -v -E ' Running | Completed |^default +first-' | head -n 40 || :
    k get pvc --no-headers 2>&1 | grep -v '^first-' || :
    k get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -n 25 | cut -c 1-600 || :
    if [[ $candidate == linstor ]]; then
      k -n "$ns" logs -l app.kubernetes.io/component=linstor-satellite -c drbd-module-loader --tail=15 2>&1 | head -n 40 || :
    fi
    if [[ $candidate == rook-ceph ]]; then
      ceph health detail 2>&1 | head -n 30 || :
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
  jq --null-input --arg c "$candidate" --argjson n "$nodes" --arg run "${GITHUB_RUN_ID:-}" \
    --rawfile m "$work/metrics" --rawfile s "$work/status" '
    def pairs(f): [f | split("\n")[] | select(. != "") | split(" ")];
    {candidate: $c, nodes: $n, run: $run,
     metrics: (pairs($m) | map({(.[0]): (.[1] | tonumber)}) | add // {}),
     status: (pairs($s) | map({(.[0]): .[1]}) | add // {})}' >"${RUNNER_TEMP:-$work}/storage-results.json" || :
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

# ceph and linstor run each tool's CLI where the candidate keeps it: Rook's operator pod holds an admin config (as the
# kubectl rook-ceph plugin uses), and LINSTOR's controller pod holds the client.
ceph() {
  k -n rook-ceph exec deploy/rook-ceph-operator -- \
    ceph --connect-timeout=10 --conf=/var/lib/rook/rook-ceph/rook-ceph.config "$@"
}
linstor() { k -n piraeus-datastore exec deploy/linstor-controller -- linstor --no-color --no-utf8 "$@"; }

# Prints "<node> <state>" for every resource of the LINSTOR volume <pv>, by the table's header names.
linstor_resources() {
  linstor resource list --resources "$1" | awk -F'|' '
    /ResourceName/ {for (i = 2; i < NF; i++) {h = $i; gsub(/ /, "", h); col[h] = i}; next}
    col["Node"] && /^\|/ && !/^\|=/ {n = $col["Node"]; s = $col["State"]; gsub(/ /, "", n); gsub(/ /, "", s); if (n != "") print n, s}'
}

# Prints the nodes holding a data replica of the volume <pv>. Rook's are by object, so it has its own path.
replica_nodes() {
  case $candidate in
    longhorn)
      k -n longhorn-system get replicas.longhorn.io -l "longhornvolume=$1" \
        -o jsonpath='{range .items[*]}{.spec.nodeID}{"\n"}{end}'
      ;;
    linstor) linstor_resources "$1" | awk '$2 !~ /Diskless|TieBreaker/ {print $1}' ;;
  esac
}

# Prints "<count> <osd>" for the OSDs in the acting sets of the objects of RBD image <image> in pool <pool> that were
# written in the last 60 s. Runs in Rook's operator pod.
ceph_objects_sh='set -euo pipefail
c=(--conf=/var/lib/rook/rook-ceph/rook-ceph.config)
prefix=$(rbd "${c[@]}" info "$1/$2" --format json | python3 -c "import json, sys; print(json.load(sys.stdin)[\"block_name_prefix\"])")
now=$(date +%s)
for o in $(rados "${c[@]}" -p "$1" ls | grep "^$prefix\."); do
  m=$(rados "${c[@]}" -p "$1" stat "$o" | sed -n "s/.* mtime \(.*\), size.*/\1/p")
  ((now - $(date -d "$m" +%s) < 60)) || continue
  ceph "${c[@]}" osd map "$1" "$o" -f json | python3 -c "import json, sys; print(*json.load(sys.stdin)[\"acting\"])"
done | tr " " "\n" | sort | uniq -c'

# Prints the OSD hosts of the objects of the RBD volume <pv> written in the last 60 s, the most-written first, so they
# hold the replicas the volume's writer is using.
ceph_active_hosts() {
  local pool image
  pool=$(k get pv "$1" -o jsonpath='{.spec.csi.volumeAttributes.pool}')
  image=$(k get pv "$1" -o jsonpath='{.spec.csi.volumeAttributes.imageName}')
  LC_ALL=C join -1 2 -2 1 -o 1.1,2.2 \
    <(k -n rook-ceph exec -i deploy/rook-ceph-operator -- bash -s -- "$pool" "$image" <<<"$ceph_objects_sh" |
      awk '{print $1, $2}' | LC_ALL=C sort -k2,2) \
    <(ceph osd tree -f json | jq --raw-output '.nodes[] | select(.type == "host") | .name as $h | .children[] | "\(.) \($h)"' |
      LC_ALL=C sort -k1,1) |
    awk '{n[$2] += $1} END {for (h in n) print n[h], h}' | sort -rn | awk '{print $2}'
}

# Succeeds once the 3-replica volume <pv> has 3 healthy replicas: Longhorn's robustness, LINSTOR's UpToDate count, or
# for Ceph every OSD up and in and every PG active+clean.
healthy3() {
  local s
  case $candidate in
    longhorn)
      [[ $(k -n longhorn-system get volumes.longhorn.io "$1" -o jsonpath='{.status.robustness}' 2>/dev/null) == healthy ]]
      ;;
    linstor) (($(linstor_resources "$1" 2>/dev/null | awk '$2 == "UpToDate"' | wc -l) == 3)) ;;
    rook-ceph)
      s=$(ceph osd stat 2>/dev/null) || return 1
      [[ $s =~ ^([0-9]+)\ osds:\ ([0-9]+)\ up.*,\ ([0-9]+)\ in ]] || return 1
      ((BASH_REMATCH[1] >= nodes && BASH_REMATCH[2] == BASH_REMATCH[1] && BASH_REMATCH[3] == BASH_REMATCH[1])) || return 1
      s=$(ceph pg stat 2>/dev/null) || return 1
      [[ $s =~ ^([0-9]+)\ pgs:\ ([0-9]+)\ active\+clean([;,]|$) ]] && ((BASH_REMATCH[1] == BASH_REMATCH[2]))
      ;;
  esac
}

# slots <node>... prints "1, 3, 4", the nodes' slots in order.
slots() {
  local n
  for n in "$@"; do echo "${slot_of[$n]:-?}"; done | sort -n | paste -sd , | sed 's/,/, /g'
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
# mounts the claim at /data and up to 300 MiB of RAM at /buf, and sees its node's name as NODE. With ready set, the pod
# turns Ready once the script has created that file.
pod_spec() {
  local probe=""
  [[ -z ${ready:-} ]] || probe="    readinessProbe: {exec: {command: [test, -e, $ready]}, periodSeconds: 1}"
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
$probe
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

# One sample per node: "<node> <pods' millicores> <pods' MiB> <node's millicores> <node's MiB>". The pods are the
# candidate's namespace. The node figures are kubectl top node's, so they include kernel work and every other pod.
sample_once() {
  local top tnodes
  top=$(k top pod -n "$ns" --no-headers 2>/dev/null) && [[ -n $top ]] || return 1
  tnodes=$(k top node --no-headers 2>/dev/null) && [[ -n $tnodes ]] || return 1
  LC_ALL=C join -a 2 -e 0 -o 0,1.2,1.3,2.2,2.3 \
    <(LC_ALL=C join \
      <(k get pod -n "$ns" --no-headers -o custom-columns=N:.metadata.name,NODE:.spec.nodeName | LC_ALL=C sort) \
      <(LC_ALL=C sort <<<"$top") |
      awk '{cpu[$2] += $3; mem[$2] += $4} END {for (n in cpu) print n, cpu[n], mem[n]}' | LC_ALL=C sort) \
    <(awk '$2 != "<unknown>" {print $1, $2 + 0, $4 + 0}' <<<"$tnodes" | LC_ALL=C sort)
}

# sample <count> <seconds apart> prints each node's median over count samples, in sample_once's columns.
sample() {
  local i
  for ((i = 0; i < $1; i++)); do
    ((i == 0)) || sleep "$2"
    sample_once || :
  done | python3 -c '
import collections, statistics, sys
rows = collections.defaultdict(list)
for line in sys.stdin:
    f = line.split()
    rows[f[0]].append([float(x) for x in f[1:]])
for node, r in rows.items():
    print(node, *(round(statistics.median(c)) for c in zip(*r)))'
}

# summarize <label> <file of sample's output> records the per-node mean of every column, and the busiest node's pod RAM.
summarize() {
  local v
  [[ -s $2 ]] || return 0
  read -r -a v < <(awk '{for (i = 2; i <= 5; i++) s[i] += $i; if ($3 > m) m = $3}
    END {printf "%d %d %d %d %d\n", s[2] / NR, s[3] / NR, s[4] / NR, s[5] / NR, m}' "$2")
  metric "pod_$1_cpu_m" "${v[0]}"
  metric "pod_$1_mib" "${v[1]}"
  metric "node_$1_cpu_m" "${v[2]}"
  metric "node_$1_mib" "${v[3]}"
  metric "pod_$1_mib_max" "${v[4]}"
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
    rook-ceph)
      cat "$work/rook-images"
      echo "quay.io/csiaddons/k8s-controller:$csiaddons_v"
      ;;
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

# Downloads and patches the candidate's manifests into $work/m before the timer, since production preloads them. Each
# patch is checked, so an upstream change fails here rather than measuring the unpatched manifest.
fetch_longhorn() {
  # D1: Longhorn's own recovery for a down node force-deletes its Deployment and StatefulSet pods. The UI is off, as
  # DESIGN.md has no third-party management UI.
  curl -fsSL "$raw/longhorn/longhorn/$longhorn_v/deploy/longhorn.yaml" |
    sed '/^  default-setting.yaml: |-$/a\    node-down-pod-deletion-policy: "delete-both-statefulset-and-deployment-pod"' |
    sed '/^  name: longhorn-ui$/,/^  replicas:/ s/^  replicas: 2$/  replicas: 0/' >"$work/m/longhorn.yaml"
  grep -q '^    node-down-pod-deletion-policy: ' "$work/m/longhorn.yaml" &&
    grep -A3 '^  name: longhorn-ui$' "$work/m/longhorn.yaml" | grep -q '^  replicas: 0$'
}

fetch_rook-ceph() {
  local ex=$raw/rook/rook/$rook_v/deploy/examples f
  for f in crds common csi-operator; do
    curl -fsSL "$ex/$f.yaml" >"$work/m/$f.yaml"
  done
  for f in crds rbac setup-controller; do
    curl -fsSL "https://github.com/csi-addons/kubernetes-csi-addons/releases/download/$csiaddons_v/$f.yaml" \
      >"$work/m/csiaddons-$f.yaml"
  done
  # operator.yaml's settings for SELinux hosts: host-path pods privileged (the mons' chown init container crash-looped
  # without it, run 36896488915) and the CSI node plugins' SELinux host mount. D1: the CSI-Addons sidecars and RBD
  # network fencing, which Rook documents for node loss and leaves off by default.
  curl -fsSL "$ex/operator.yaml" |
    sed '/name: ROOK_HOSTPATH_REQUIRES_PRIVILEGED/{n;s/"false"/"true"/}
      s/^    deployCsiAddons: false$/    deployCsiAddons: true/
      s/^      enableSeLinuxHostMount: false$/      enableSeLinuxHostMount: true/' |
    awk '/name: rook-ceph.rbd.csi.ceph.com/ {rbd = 1} {print} rbd && /^spec:$/ {print "  enableFencing: true"; rbd = 0}' \
      >"$work/m/operator.yaml"
  # The upstream example CephCluster, dashboard off. Its keys with no value (csi.cephfs, resources and others) go, as
  # kubectl create drops them: server-side apply rejected "spec.csi.cephfs ... must be of type object" (run 36932898763).
  curl -fsSL "$ex/cluster.yaml" | sed '/^  dashboard:$/,/enabled:/ s/enabled: true/enabled: false/' | awk '
    {line[NR] = $0}
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^ *[A-Za-z0-9_.-]+: *(#.*)?$/) {
          ind = match(line[i], /[^ ]/)
          for (j = i + 1; j <= NR && line[j] ~ /^ *(#.*)?$/; j++) {}
          if (j > NR || match(line[j], /[^ ]/) <= ind && line[j] !~ /^ *- /) continue
        }
        print line[i]
      }
    }' >"$work/m/cluster.yaml"
  grep -A1 'name: ROOK_HOSTPATH_REQUIRES_PRIVILEGED' "$work/m/operator.yaml" | grep -q '"true"' &&
    grep -q '^    deployCsiAddons: true$' "$work/m/operator.yaml" &&
    grep -q '^      enableSeLinuxHostMount: true$' "$work/m/operator.yaml" &&
    grep -q '^  enableFencing: true$' "$work/m/operator.yaml" &&
    grep -A1 '^  dashboard:$' "$work/m/cluster.yaml" | grep -q 'enabled: false' &&
    ! grep -q '^    cephfs:$' "$work/m/cluster.yaml" &&
    grep -q "image: $ceph_image\$" "$work/m/cluster.yaml"
}

fetch_linstor() {
  curl -fsSL "https://github.com/piraeusdatastore/piraeus-operator/releases/download/$piraeus_v/manifest.yaml" \
    >"$work/m/manifest.yaml"
}

install_longhorn() {
  k apply --server-side --force-conflicts -f "$work/m/longhorn.yaml" >/dev/null || return 1
  local p=(staleReplicaTimeout=30 dataEngine=v1)
  {
    sc spike-r1 driver.longhorn.io numberOfReplicas=1 dataLocality=strict-local "${p[@]}"
    sc spike-r3 driver.longhorn.io numberOfReplicas=3 "${p[@]}"
    sc spike-rwx driver.longhorn.io numberOfReplicas=3 "${p[@]}"
    sc spike-block driver.longhorn.io numberOfReplicas=3 migratable=true "${p[@]}"
  } | apply_until
}

install_rook-ceph() {
  local s=csi.storage.k8s.io f
  for f in crds common csi-operator; do
    k apply --server-side --force-conflicts -f "$work/m/$f.yaml" >/dev/null || return 1
  done
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
    # CSI-Addons' rbac.yaml needs the namespace its setup-controller.yaml creates, and operator.yaml holds CSI operator
    # resources whose CRDs csi-operator.yaml only just created, so they go through the retrying apply.
    for f in crds rbac setup-controller; do
      cat "$work/m/csiaddons-$f.yaml"
      echo "---"
    done
    cat "$work/m/operator.yaml"
    echo "---"
    cat "$work/m/cluster.yaml"
    # The pools and filesystem of deploy/examples/csi/rbd/storageclass.yaml and filesystem.yaml under other names, and
    # a size-1 pool, which Rook allows by default (mon allow pool size one).
    cat <<'EOF'
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
    requireSafeReplicaSize: true
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
  k apply --server-side --force-conflicts -f "$work/m/manifest.yaml" >/dev/null || return 1
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
    # The 1-replica class keeps the replica on the consumer's node, as Longhorn's strict-local does.
    sc spike-r1 $l "$l/storagePool=pool1" "$l/placementCount=1" "$l/allowRemoteVolumeAccess=false"
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

# Builds and loads DRBD on every node before the timer with Piraeus's loader image and its satellite init container's
# settings, since production ships a module. The satellites' loaders then find it loaded and exit at once.
prebuild_drbd() {
  local loader
  loader=$(printf '%s\n' "${images[@]}" | awk '/\/drbd9-almalinux10:/ && !f {print; f = 1}')
  k apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: drbd-prebuild
spec:
  selector:
    matchLabels: {app: drbd-prebuild}
  template:
    metadata:
      labels: {app: drbd-prebuild}
    spec:
      initContainers:
        - name: drbd-module-loader
          image: $loader
          env:
            - {name: LB_FAIL_IF_USERMODE_HELPER_NOT_DISABLED, value: "yes"}
            - {name: LB_DRBD_MIN_LOADED_VERSION, value: "9"}
            - {name: LB_SELINUX_AS, value: modules_object_t}
          securityContext:
            readOnlyRootFilesystem: true
            seLinuxOptions: {type: spc_t, level: s0}
            capabilities: {drop: [ALL], add: [SYS_MODULE]}
          volumeMounts:
            - {name: lib-modules, mountPath: /lib/modules, readOnly: true}
            - {name: usr-src, mountPath: /usr/src, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      containers:
        - name: done
          image: $debian
          command: [sleep, infinity]
      volumes:
        - {name: lib-modules, hostPath: {path: /lib/modules, type: Directory}}
        - {name: usr-src, hostPath: {path: /usr/src, type: Directory}}
        - {name: tmp, emptyDir: {}}
EOF
  k rollout status ds/drbd-prebuild --timeout=15m >/dev/null || return 1
  k get pods -l app=drbd-prebuild -o json | jq --raw-output '
    [.items[].status.initContainerStatuses[]? | .state.terminated // empty
      | (.finishedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)] | "\(length) \(max)"'
}

# The node killed holds a replica of slot 1's 3-replica volume, and is neither slot 1's, which runs this, nor the VIP
# holder, which serves the API. D1: each candidate recovers with its own mechanism.
failover() {
  local holder victim="" s t_kill t_nr="" back="" where="" p off writes gap name pv cand on_victim mech io where_reps
  local -a reps
  holder=$(vip_ssh hostname)
  local writer='while :; do
  if echo "$(date +%s.%N) $NODE" | dd of=/data/log oflag=append conv=notrunc,fsync status=none; then
    echo "W $(date +%s.%N) $NODE"
  fi
  sleep 0.5
done'
  { pvc fo-survivor spike-r3 1Gi ReadWriteOnce; pod fo-survivor fo-survivor "$writer" "$me"; } | k apply -f - >/dev/null
  SECONDS=0
  until k logs fo-survivor 2>/dev/null | grep -q '^W'; do
    ((SECONDS < 600)) || { failed "Storage node killed" "slot 1's writer did not start in 10 min"; return; }
    sleep 3
  done
  # Ceph's replicas are per object, so it needs writes from the last minute to find the ones in use.
  sleep 20
  pv=$(k get pvc fo-survivor -o jsonpath='{.spec.volumeName}')
  if [[ $candidate == rook-ceph ]]; then
    mapfile -t reps < <(ceph_active_hosts "$pv" || :)
    where_reps="slot 1's volume wrote to objects on the OSDs of slots $(slots "${reps[@]}")"
  else
    mapfile -t reps < <(replica_nodes "$pv" || :)
    where_reps="slot 1's volume has replicas on slots $(slots "${reps[@]}")"
  fi
  for cand in "${reps[@]}"; do
    if [[ $cand != "$me" && $cand != "$holder" ]]; then
      victim=$cand
      break
    fi
  done
  [[ -n $victim ]] || { failed "Storage node killed" "no replica holder besides slot 1 and the VIP holder: $where_reps"; return; }
  on_victim=$(k -n "$ns" get pods --field-selector "spec.nodeName=$victim" --no-headers -o custom-columns=N:.metadata.name |
    sed -E 's/-[bcdfghjklmnpqrstvwxz2456789]{6,10}-[bcdfghjklmnpqrstvwxz2456789]{5}$//
      s/-[bcdfghjklmnpqrstvwxz2456789]{5}$//' | sort -u | paste -sd , | sed 's/,/, /g')
  # The victim's writer is a Deployment, so it is recreated on another node. It prefers the victim, rather than having
  # the other nodes cordoned, since Longhorn places no replica on a cordoned node and its volume then lived only on the
  # victim. It tolerates a not-ready or unreachable node for 10 s instead of 300 s, so the time measured is the
  # storage's rather than the eviction's.
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
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - {key: kubernetes.io/hostname, operator: In, values: [$victim]}
      tolerations:
        - {key: node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 10}
        - {key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 10}
$(restart=Always pod_spec fo-victim "$writer" | sed 's/^/      /')
EOF
  } | k apply -f - >/dev/null
  # Up to 3 tries for the writer to start on the victim. A pod elsewhere is deleted, and the Deployment makes another.
  local tries=0 on vpv vreps="" ok=""
  SECONDS=0
  while ((tries < 3 && SECONDS < 600)); do
    if k logs deploy/fo-victim 2>/dev/null | grep -q '^W'; then
      on=$(k get pods -l app=fo-victim --field-selector status.phase=Running -o jsonpath='{.items[0].spec.nodeName}')
      [[ $on != "$victim" ]] || { ok=1; break; }
      tries=$((tries + 1))
      log "fo-victim started on $on, not $victim: deleting it (try $tries of 3)"
      k delete pod -l app=fo-victim --wait=true >/dev/null
    fi
    sleep 3
  done
  [[ -n $ok ]] || { failed "Storage node killed" "the killed node's writer did not start on slot ${slot_of[$victim]}"; return; }
  # Its volume must have 3 healthy replicas on 3 nodes before the kill.
  vpv=$(k get pvc fo-victim -o jsonpath='{.spec.volumeName}')
  SECONDS=0
  until [[ -n $vreps ]]; do
    if healthy3 "$vpv"; then
      # Node names hold no spaces.
      # shellcheck disable=SC2046
      if [[ $candidate == rook-ceph ]]; then
        vreps="the killed node's volume wrote to objects on the OSDs of slots $(slots $(ceph_active_hosts "$vpv"))"
      elif (($(replica_nodes "$vpv" | sort -u | wc -l) == 3)); then
        # shellcheck disable=SC2046
        vreps="the killed node's volume has replicas on slots $(slots $(replica_nodes "$vpv"))"
      fi
    fi
    if [[ -z $vreps ]]; then
      ((SECONDS < 300)) || { failed "Storage node killed" "the killed node's volume had not 3 healthy replicas on 3 nodes in 5 min"; return; }
      sleep 5
    fi
  done
  # The node's clock minus this runner's, to place the survivor's write times.
  off=$(awk -v r="$EPOCHREALTIME" -v n="$(node_ssh "${ip_of[$me]}" date +%s.%N)" 'BEGIN {printf "%.3f", n - r}')
  log "powering off $victim (slot ${slot_of[$victim]})"
  t_kill=$EPOCHREALTIME
  # A powered-off peer never closes the connection, so the ssh runs into its timeout.
  (node_ssh "${ip_of[$victim]}" 'sudo systemctl poweroff --force --force' </dev/null || :) &
  while [[ -z $back ]] && ((EPOCHSECONDS - ${t_kill%.*} < 600)); do
    if [[ -z $t_nr && $(k get node "$victim" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') != True ]]; then
      t_nr=$EPOCHREALTIME
      if [[ $candidate == rook-ceph ]]; then
        k taint node "$victim" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute >/dev/null
        k taint node "$victim" node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule >/dev/null
      fi
    fi
    for p in $(k get pods -l app=fo-victim -o jsonpath='{range .items[*]}{.metadata.name}={.spec.nodeName}{"\n"}{end}'); do
      if [[ -n ${p#*=} && ${p#*=} != "$victim" ]] && k logs "${p%=*}" 2>/dev/null | grep -q '^W'; then
        back=$EPOCHREALTIME
        where=${p#*=}
      fi
    done
    sleep 2
  done
  # The survivor's longest time without a write from 5 s before the kill to 180 s after, counting the window's edges,
  # so a stall that outlasts the window still counts.
  while ((EPOCHSECONDS - ${t_kill%.*} < 185)); do sleep 5; done
  read -r writes gap < <(k logs fo-survivor | survivor_gap "$t_kill" "$off")
  case $candidate in
    linstor) mech="Piraeus HA controller, on by default" ;;
    longhorn) mech="node-down-pod-deletion-policy=delete-both-statefulset-and-deployment-pod" ;;
    rook-ceph) mech="CSI-Addons network fencing, with the out-of-service taint applied by this script at NotReady. Rook \
documents the taint as an admin's step once the node is confirmed down, and ships no automation for it" ;;
  esac
  local nr="never NotReady in 10 min"
  if [[ -n $t_nr ]]; then
    nr="NotReady $(awk -v a="$t_kill" -v b="$t_nr" 'BEGIN {printf "%.0f", b - a}') s after the kill"
    metric kill_notready_s "$(awk -v a="$t_kill" -v b="$t_nr" 'BEGIN {printf "%.0f", b - a}')"
  fi
  metric survivor_gap_s "$gap"
  metric survivor_writes "$writes"
  io="Slot 1's 3-replica volume: $writes writes from 5 s before the kill to 180 s after, longest gap ${gap} s ($where_reps;
$vreps)."
  local head="Storage node killed (slot ${slot_of[$victim]}, ran: ${on_victim:-no pod of the candidate})"
  if [[ -n $back ]]; then
    metric kill_back_s "$(awk -v a="$t_kill" -v b="$back" 'BEGIN {printf "%.0f", b - a}')"
    [[ -z $t_nr ]] || metric notready_back_s "$(awk -v a="$t_nr" -v b="$back" 'BEGIN {printf "%.0f", b - a}')"
    status kill ok
    row "$head" "$io The killed node's pod wrote again on slot ${slot_of[$where]} \
$(awk -v a="$t_kill" -v b="$back" 'BEGIN {printf "%.0f", b - a}') s after the kill \
($nr$([[ -z $t_nr ]] || awk -v a="$t_nr" -v b="$back" 'BEGIN {printf ", %.0f s after NotReady", b - a}')). Recovery: $mech."
  else
    status kill failed
    attach_diag "$(k get pvc fo-victim -o jsonpath='{.spec.volumeName}')" "fo-victim"
    failed "$head" "$io The killed node's pod had not written again 10 min after the kill ($nr). Recovery: $mech."
  fi
}

# attach_diag <pv> <label>: what holds the volume <pv> after a failed reattach, into the job summary.
attach_diag() {
  {
    echo "<details><summary>Attachments of $2 ($1)</summary>"
    echo
    echo '```'
    k get volumeattachments -o wide 2>&1 | grep -E "ATTACHER|$1" || :
    case $candidate in
      longhorn)
        k -n longhorn-system get volumes.longhorn.io "$1" \
          -o jsonpath='{.status.state} {.status.robustness} on {.status.currentNodeID}{"\n"}' 2>&1 || :
        k -n longhorn-system get volumeattachments.longhorn.io "$1" -o jsonpath='{.spec}{"\n"}{.status}{"\n"}' 2>&1 || :
        k -n longhorn-system get replicas.longhorn.io -l "longhornvolume=$1" -o jsonpath='{range .items[*]}{.spec.nodeID} \
{.status.currentState} healthyAt={.spec.healthyAt} failedAt={.spec.failedAt}{"\n"}{end}' 2>&1 || :
        ;;
      linstor) linstor resource list --resources "$1" 2>&1 || : ;;
    esac
    for p in $(k get pods -l "app=$2" -o name 2>/dev/null); do
      k describe "$p" 2>&1 | sed -n '/^Events:/,$p' | tail -n 8 || :
    done
    echo '```'
    echo "</details>"
    echo
  } >>"$work/diag"
}

# vm_diag: why the VM did not start or migrate, into the job summary.
vm_diag() {
  {
    echo "<details><summary>KubeVirt VM and migration</summary>"
    echo
    echo '```'
    k get vmim mig1 -o jsonpath='{.status}{"\n"}' 2>&1 || :
    k get pods -l kubevirt.io=virt-launcher -o wide 2>&1 || :
    k get events --field-selector reason=FailedScheduling -o custom-columns=OBJ:.involvedObject.name,MSG:.message 2>&1 | tail -n 5 || :
    k get pv "$(k get pvc vm-disk -o jsonpath='{.spec.volumeName}')" -o jsonpath='PV node affinity: {.spec.nodeAffinity}{"\n"}' 2>&1 || :
    k get nodes -L kubevirt.io/schedulable 2>&1 || :
    echo '```'
    echo "</details>"
    echo
  } >>"$work/diag"
}

# Reads `kubectl logs` of a writer and prints "<writes> <longest gap>" over [t - 5, t + 180], where t is the kill time
# <t> on this runner's clock and <off> the writer's node clock minus this runner's.
survivor_gap() {
  awk -v t="$1" -v off="$2" '$1 == "W" {
    ts = $2 - off
    if (ts >= t - 5 && ts <= t + 180) { g = ts - (n ? prev : t - 5); if (g > max) max = g; prev = ts; n++ } }
    END {g = t + 180 - (n ? prev : t - 5); if (g > max) max = g; printf "%d %.1f\n", n, max}'
}

# Denials since prep on every node, by command, from every audit log including rotated ones. Writes the row's text to
# $work/avc and fails when a node's audit log cannot be read.
avc() {
  local name out bad=0
  : >"$work/avc-lines"
  : >"$work/avc-counts"
  for name in "${!ip_of[@]}"; do
    if out=$(node_ssh "${ip_of[$name]}" sudo bash -s -- "${since:-0}" <<'EOF'
set -euo pipefail
test -r /var/log/audit/audit.log || { echo "no readable /var/log/audit/audit.log"; exit 3; }
rc=0
# shellcheck disable=SC2046
out=$(ausearch --raw -m AVC,USER_AVC -ts $(date -d "@$1" '+%x %T') 2>/tmp/ausearch.err) || rc=$?
if ((rc == 1)) && grep -q '<no matches>' /tmp/ausearch.err; then
  echo "0 none"
  exit 0
fi
((rc == 0)) || { echo "ausearch failed: $(head -c 200 /tmp/ausearch.err)"; exit 3; }
denied=$(grep 'avc: *denied' <<<"$out" || :)
[[ -n $denied ]] || { echo "0 none"; exit 0; }
echo "$(wc -l <<<"$denied") $(sed -nE 's/.*(comm|exe)="([^"]*)".*/\2/p' <<<"$denied" | sort | uniq -c | sort -rn |
  awk 'NR <= 5 {printf "%s%s x%s", s, $2, $1; s = ", "}')"
EOF
    ); then
      echo "${out%% *}" >>"$work/avc-counts"
      echo "slot ${slot_of[$name]}: ${out#* }" >>"$work/avc-lines"
    else
      bad=1
      echo "slot ${slot_of[$name]}: ${out:-unreadable}" >>"$work/avc-lines"
    fi
  done
  sort "$work/avc-lines" | paste -sd ';' | sed 's/;/; /g' >"$work/avc"
  metric avc_denials "$(awk '{s += $1} END {print s + 0}' "$work/avc-counts")"
  ((bad == 0))
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
KubeVirt $kubevirt_v with software emulation."
case $candidate in
  longhorn)
    note "Config: upstream longhorn.yaml with node-down-pod-deletion-policy=delete-both-statefulset-and-deployment-pod \
(D1) and longhorn-ui scaled to 0. Classes: spike-r1 numberOfReplicas 1 with dataLocality strict-local, spike-r3 and \
spike-rwx 3, spike-block 3 and migratable, all WaitForFirstConsumer with staleReplicaTimeout 30 and dataEngine v1."
    ;;
  rook-ceph)
    note "Config: upstream crds, common, csi-operator, operator and cluster.yaml, with ROOK_HOSTPATH_REQUIRES_PRIVILEGED=true \
and nodePlugin.enableSeLinuxHostMount=true (operator.yaml's settings for SELinux hosts), deployCsiAddons=true and the \
RBD Driver's enableFencing=true plus the CSI-Addons $csiaddons_v controller (D1, off by default upstream), and the \
dashboard off. OSDs on every empty device (upstream useAllDevices), which is vdb. Pools as the examples under other \
names: spike-r3 size 3, spike-r1 size 1, CephFilesystem spike-fs with size-3 pools and one active MDS plus a standby."
    ;;
  linstor)
    note "Config: upstream manifest.yaml unchanged, LinstorCluster {} and an LVM thin pool on vdb. Classes: spike-r1 \
placementCount 1 with allowRemoteVolumeAccess=false, the others placementCount 3, all WaitForFirstConsumer. Secure Boot \
off, since the DRBD module is built here and unsigned."
    ;;
esac
note "Timed: from the first kubectl apply of the candidate's downloaded manifests until a pod has written 1 MiB with \
fsync to a new 3-replica PVC and that volume has 3 healthy replicas. That includes the candidate's own disk setup \
(LINSTOR's LVM thin pool, Ceph's OSD prepare) and Rook's CSI-Addons controller. Untimed, before it: manifest \
downloads, image pulls, host packages, Longhorn's data disk format and mount, and LINSTOR's DRBD module build."

# Preparation, untimed.
log "preparing every node"
since=$EPOCHSECONDS
curl -fsSL "$raw/rook/rook/$rook_v/deploy/examples/images.txt" >"$work/rook-images"
ceph_image=$(grep -m 1 '^quay.io/ceph/ceph:' "$work/rook-images")
mapfile -t images < <({
  candidate_images
  printf '%s\n' "quay.io/kubevirt/virt-"{operator,api,controller,handler,launcher}":$kubevirt_v" "$cirros" "$debian"
} | sort -u)
if ! "fetch_$candidate"; then
  failed "Manifests" "a download or an expected patch failed"
  exit 1
fi
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

if [[ $candidate == linstor ]]; then
  log "building DRBD on every node"
  SECONDS=0
  if built=$(prebuild_drbd); then
    read -r loaders slowest <<<"$built"
    metric drbd_build_s "$slowest"
    row "DRBD module build and load, Piraeus's loader image, untimed prep" "$loaders nodes, the slowest in $slowest s"
  else
    failed "DRBD module build and load, untimed prep" "the loaders did not finish in ${SECONDS} s"
  fi
  k delete ds drbd-prebuild --wait=true >/dev/null || :
fi

# Timed: from the first apply to a pod's 1 MiB fsync'd write to a new 3-replica PVC whose volume then has 3 healthy
# replicas. A new PVC and pod every 15 s until one writes, so no attempt waits out the CSI provisioner's back-off. An
# attempt's pod stays up, and Ready, after its write, so its volume stays attached and Longhorn reports its health.
log "installing $candidate"
t0=$EPOCHSECONDS
if ! "install_$candidate"; then
  failed "Install" "kubectl apply failed after $((EPOCHSECONDS - t0)) s: $(tail -n 3 "$work/apply.err" 2>/dev/null)"
  exit 1
fi
log "applied after $((EPOCHSECONDS - t0))s, waiting for a writable 3-replica PVC with 3 healthy replicas"
attempt='dd if=/dev/urandom of=/data/f bs=1M count=1 conv=fsync || exit 1
touch /tmp/wrote
exec sleep infinity'
n=0 next=0 winner="" t_write="" t_healthy=""
while ((EPOCHSECONDS - t0 < 1500)); do
  if [[ -z $winner ]]; then
    winner=$(k get pods -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
      awk '$1 ~ /^first-/ && $2 == "True" && !f {print $1; f = 1}')
    [[ -z $winner ]] || { t_write=$EPOCHSECONDS; log "$winner wrote after $((t_write - t0))s"; }
  fi
  if [[ -n $winner ]]; then
    if healthy3 "$(k get pvc "$winner" -o jsonpath='{.spec.volumeName}')"; then
      t_healthy=$EPOCHSECONDS
      break
    fi
  elif ((EPOCHSECONDS >= next)); then
    n=$((n + 1))
    { pvc "first-$n" spike-r3 1Gi ReadWriteOnce
      ready=/tmp/wrote pod "first-$n" "first-$n" "$attempt"; } | k apply -f - >/dev/null || :
    next=$((EPOCHSECONDS + 15))
  fi
  sleep 2
done
mapfile -t pulled < <(k get events -A --field-selector reason=Pulling -o json | jq --raw-output --argjson t0 "$t0" '
  .items[] | select(((.lastTimestamp // .eventTime // .firstTimestamp // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $t0)
  | .message' | sort -u)
pulls="image pulls during the timing: ${pulled[*]:-none}"
if [[ $candidate == linstor ]]; then
  pulls+=". The satellites' DRBD loaders took $(k -n "$ns" get pods -o json | jq --raw-output '
    [.items[].status.initContainerStatuses[]? | select(.name == "drbd-module-loader") | .state.terminated // empty
      | (.finishedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)] | "at most \(max // "n/a") s"')"
fi
case $candidate in
  longhorn) cond="robustness healthy" ;;
  linstor) cond="3 resources UpToDate" ;;
  rook-ceph) cond="every OSD up and in, at least $nodes, and every PG active+clean" ;;
esac
if [[ -z $t_write ]]; then
  failed "Install start to the first fsync'd write to a 3-replica PVC" \
    "none after $((EPOCHSECONDS - t0)) s and $n attempts; $pulls"
  exit 1
fi
row "Install start to the first fsync'd write to a 3-replica PVC" "$((t_write - t0)) s ($winner of $n attempts); $pulls"
metric install_write_s "$((t_write - t0))"
if [[ -z $t_healthy ]]; then
  failed "Install start to 3 healthy replicas ($cond)" "not after $((EPOCHSECONDS - t0)) s"
else
  row "Install start to 3 healthy replicas ($cond)" "$((t_healthy - t0)) s"
  metric install_healthy_s "$((t_healthy - t0))"
fi
mapfile -t attempts < <(seq -f 'first-%g' 1 "$n")
k delete pod,pvc --ignore-not-found --wait=false "${attempts[@]}" >/dev/null

# Idle: once the attempts' volumes are gone and the candidate's pods have stopped restarting.
log "waiting for the attempts' volumes to go and the candidate's pods to settle"
SECONDS=0
until ! k get pv -o jsonpath='{range .items[*]}{.spec.claimRef.name}{"\n"}{end}' | grep -q '^first-'; do
  ((SECONDS < 600)) || { note "Idle sample: attempts' PVs still present after 10 min."; break; }
  sleep 5
done
settle() {
  k get pods -n "$ns" --no-headers 2>/dev/null |
    awk '{split($2, r, "/"); if ($3 != "Running" && $3 != "Completed" || ($3 == "Running" && r[1] != r[2])) bad++; s += $4}
      END {print s + 0, bad + 0}'
}
prev=$(settle)
SECONDS=0
while sleep 30; now=$(settle); [[ $now != "$prev" || ${now#* } != 0 ]]; do
  ((SECONDS < 600)) || { note "Idle sample: the candidate's pods still restarting or not ready after 10 min ($now)."; break; }
  prev=$now
done
log "settled after ${SECONDS}s, sampling idle"
sample 5 10 >"$work/idle"
summarize idle "$work/idle"

ingest='head -c 64M /dev/urandom >/buf/r
echo START
n=0 bad=0 i=0 start=$(date +%s.%N) end=$((SECONDS + 60))
while ((SECONDS < end)); do
  if dd if=/buf/r of=/data/f bs=4M count=16 oflag=direct conv=notrunc seek=$((i % 48 * 16)) status=none; then
    n=$((n + 1))
  else
    bad=$((bad + 1))
  fi
  i=$((i + 1))
done
echo "RESULT $n $bad $start $(date +%s.%N)"'
mapfile -t peer_mibs < <(for ((s = 2; s <= nodes; s++)); do
  [[ -n ${node_at[$s]:-} ]] || continue
  node_ssh "${ip_of[${node_at[$s]}]}" 'iperf3 --server --one-off --daemon' </dev/null
  sleep 1
  ssh_timeout=60 node_ssh "${ip_of[$me]}" "iperf3 --client ${ip_of[${node_at[$s]}]} --time 10 --json" </dev/null |
    jq --raw-output "\"$s \\(.end.sum_received.bits_per_second / 8388608 | floor)\"" || echo "$s failed"
done)
row "TCP from slot 1's node to each other node, iperf3 for 10 s on the node network" \
  "$(printf '%s\n' "${peer_mibs[@]}" | awk '{printf "%sslot %s %s", s, $1, ($2 == "failed" ? "failed" : $2 " MiB/s"); s = ", "}')"
metric iperf_mibs "$(printf '%s\n' "${peer_mibs[@]}" | awk '$2 != "failed" {print $2}' |
  python3 -c 'import statistics, sys; v = [float(x) for x in sys.stdin]; print(round(statistics.median(v)) if v else "")')"
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
    sleep 20
    sample 3 10 >"$work/ingest"
    summarize ingest "$work/ingest"
  fi
  pv=$(k get pvc "$name" -o jsonpath='{.spec.volumeName}')
  if [[ $candidate == rook-ceph ]]; then
    placed="spread over the pool's PGs on every OSD by design, Ceph has no local placement"
  else
    # shellcheck disable=SC2046
    placed="replicas on slots $(slots $(replica_nodes "$pv"))"
  fi
  if k wait "pod/$name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m >/dev/null 2>&1 &&
    line=$(k logs "$name" | grep '^RESULT'); then
    read -r _ ok bad st en <<<"$line"
    mibs=$(awk -v n="$ok" -v a="$st" -v b="$en" 'BEGIN {printf "%.0f", n * 64 / (b - a)}')
    metric "ingest_r${r}_mibs" "$mibs"
    row "Ingest, $r replica" "$mibs MiB/s over $(awk -v a="$st" -v b="$en" 'BEGIN {printf "%.0f", b - a}') s, \
$ok writes of 64 MiB, $bad failed, writer on slot 1, $placed. Slot 1's tailnet paths: $(paths)"
  else
    failed "Ingest, $r replica" "the writer did not finish ($(k get pod "$name" -o jsonpath='{.status.phase}')), $placed"
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
  ((SECONDS < 300)) || break
  sleep 3
done
if ((SECONDS < 300)); then
  status rwx ok
  metric rwx_s "$SECONDS"
  row "RWX filesystem mounted on two nodes" "pods on slots 1 and 2 each read the other's file ${SECONDS} s after the PVC"
else
  {
    echo "<details><summary>RWX pods and volume</summary>"
    echo
    echo '```'
    for p in rwx-a rwx-b; do
      echo "== $p"
      k logs "$p" --tail=20 2>&1 || :
      k describe pod "$p" 2>&1 | tail -n 15 || :
    done
    if [[ $candidate == rook-ceph ]]; then
      ceph fs status 2>&1 || :
      for p in $(k -n rook-ceph get pods -o wide --no-headers | awk -v a="$me" -v b="$other" \
        '$1 ~ /cephfs.*nodeplugin/ && ($7 == a || $7 == b) {print $1}'); do
        echo "== $p"
        k -n rook-ceph logs "$p" --all-containers --tail=15 2>&1 || :
      done
    fi
    echo '```'
    echo "</details>"
    echo
  } >>"$work/diag"
  if [[ $candidate == rook-ceph ]]; then
    status rwx inconclusive
    inconclusive "RWX filesystem mounted on two nodes" "the pods did not both see both files in 5 min, cause not yet found"
  else
    status rwx failed
    failed "RWX filesystem mounted on two nodes" "the pods did not both see both files in 5 min"
  fi
fi
k delete pod rwx-a rwx-b --wait=false >/dev/null

if [[ -n $kubevirt ]]; then
  log "KubeVirt live migration"
  cpu_model=$(k get nodes -o json | jq --raw-output '
    [.items[] | [.metadata.labels | to_entries[] | select(.value == "true" and (.key | startswith("cpu-model.node.kubevirt.io/")))
      | .key | sub(".*/"; "")]]
    | reduce .[1:][] as $n (.[0]; map(select(. as $m | $n | index($m))))
    | (map(select(IN("Westmere", "Nehalem", "SandyBridge", "Opteron_G3", "EPYC"))) + .) | .[0] // empty')
  note "KubeVirt VM CPU model: ${cpu_model:-host-model, as no named model is usable on every node}."
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
    cpu: {model: ${cpu_model:-host-model}}
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
      status migrate ok
      metric migrate_s "$SECONDS"
      row "KubeVirt VM on an RWX block volume live-migrates" \
        "from slot ${slot_of[$from]} to slot ${slot_of[$to]}, ${SECONDS} s from the migration's creation"
    else
      status migrate failed
      vm_diag
      failed "KubeVirt VM on an RWX block volume live-migrates" "phase ${phase:-none} after ${SECONDS} s: \
$(k get vmi vm1 -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].message}' 2>&1) \
$(k get vmim mig1 -o jsonpath='{.status.migrationState.failureReason}' 2>&1)"
    fi
  else
    status migrate failed
    vm_diag
    failed "KubeVirt VM on an RWX block volume live-migrates" "the VM was not Running after 10 min"
  fi
fi

if avc; then
  row "SELinux denials since prep (ausearch, rotated logs included)" "$(cat "$work/avc")"
else
  failed "SELinux denials since prep (ausearch, rotated logs included)" "$(cat "$work/avc")"
fi

if [[ $candidate == rook-ceph ]]; then
  note "Ceph osd_memory_target: $(ceph config get osd osd_memory_target 2>&1 | tr -d '\r') bytes. OSDs have no memory \
limit, so their RAM grows toward it as their caches fill."
fi

log "killing a storage node"
failover

log "sampling at the end of the run"
sample 3 10 >"$work/end"
summarize end "$work/end"

{
  echo "Per node: the candidate's pods (namespace $ns, kubectl top pod) and the whole node (kubectl top node, which \
counts kernel work such as DRBD, dm-thin, krbd and iSCSI, and every other pod). Idle is the median of 5 samples 10 s \
apart once the attempts' volumes were gone and the candidate's pods had stopped restarting, ingest the median of 3 \
during the 3-replica ingest, end the median of 3 after the node kill."
  echo
  echo "| Node | Pods idle | Node idle | Pods ingest | Node ingest | Pods end | Node end |"
  echo "|---|---|---|---|---|---|---|"
  for ((s = 1; s <= nodes; s++)); do
    name=${node_at[$s]:-}
    [[ -n $name ]] || continue
    printf '| slot %s |' "$s"
    for f in idle ingest end; do
      awk -v n="$name" '$1 == n {printf " %d m, %d MiB | %d m, %d MiB |", $2, $3, $4, $5; x = 1}
        END {if (!x) printf " n/a | n/a |"}' "$work/$f" 2>/dev/null || printf ' n/a | n/a |'
    done
    echo
  done
} >"$work/resources"
((failures == 0))
