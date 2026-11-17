#!/usr/bin/env bash
# Spike: compare the slurm-singularity-exec SPANK plugin with the native
# Slurm --container option (oci.conf) when both use Apptainer.
#
# Runs on a Linux host with Docker and sind. Creates one sind cluster with
# the Slurm image given in SIND_IMAGE, runs each probe and writes a Markdown
# result table to $OUT/results.md. A probe that fails does not stop the run.
set -uo pipefail

SIND=${SIND:-sind}
SIND_IMAGE=${SIND_IMAGE:-ghcr.io/gsi-hpc/sind-node:26.05}
SIF_SOURCE=${SIF_SOURCE:-docker://docker.io/library/ubuntu:24.04}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out}
NODES=(controller worker-0 worker-1)
WORKERS=(worker-0 worker-1)
SIF=/data/spike/out/c.sif

mkdir -p "$OUT"
RES=$OUT/results.md
LOG=$OUT/log.txt
: >"$LOG"
{
  echo "## Image \`$SIND_IMAGE\`"
  echo
  echo "| ID | Probe | Observed | Seconds |"
  echo "|---|---|---|---|"
} >"$RES"

log() { echo "== $*" | tee -a "$LOG"; }

# on NODE: run stdin as a root bash script on NODE
on() { "$SIND" ssh "$1" -- bash -s; }

# as_alice: run stdin as a bash script as user alice on the submit node
as_alice() { "$SIND" exec -u alice -- bash -s; }

# obs ID PROBE: run stdin as alice, record its output (one line) and duration
obs() {
  local id=$1 probe=$2 out t0 t1
  t0=$(date +%s.%N)
  out=$(as_alice 2>&1 | tee -a "$LOG" | tr '\n' ' ' | sed 's/|/\\|/g' | cut -c1-400)
  t1=$(date +%s.%N)
  printf '| %s | %s | `%s` | %s |\n' "$id" "$probe" "$out" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')" >>"$RES"
  log "$id: $out"
}

# Probe run in each task, from the shared home directory, which Apptainer
# binds by default. Prints the OS of the root file system, the task rank, a
# variable that TaskProlog sets, the soft stack limit, a variable with
# special characters from the submit environment, the number of SLURM_*
# variables and the working directory.
PROBE=/home/alice/probe.sh
SUBMIT_ENV='export WEIRD='\''a b"c$d'\''; ulimit -S -s 4096'

# /etc/slurm is a read-only mount of a Docker volume in sind nodes, so
# write oci.conf into that volume from the Docker host.
conf_volume() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/slurm"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}' "$1"
}

write_oci_conf() { # $1: content
  local n vol
  for n in "${WORKERS[@]}"; do
    vol=$(conf_volume "sind-default-$n")
    printf '%s\n' "$1" | docker run --rm -i -v "$vol:/v" busybox sh -c 'cat > /v/oci.conf' 2>>"$LOG"
    echo "cat /etc/slurm/oci.conf; systemctl restart slurmd" | on "$n" >>"$LOG" 2>&1
  done
  echo 'for i in $(seq 60); do sinfo -h -o %T | grep -qv idle || exit 0; sleep 2; done; sinfo' | on controller >>"$LOG" 2>&1
}

remove_oci_conf() {
  local n vol
  for n in "${WORKERS[@]}"; do
    vol=$(conf_volume "sind-default-$n")
    docker run --rm -v "$vol:/v" busybox rm -f /v/oci.conf 2>>"$LOG"
    echo 'ls /etc/slurm; systemctl restart slurmd' | on "$n" >>"$LOG" 2>&1
  done
  echo 'for i in $(seq 60); do sinfo -h -o %T | grep -qv idle || exit 0; sleep 2; done; sinfo' | on controller >>"$LOG" 2>&1
}

###############################################################################
log "create cluster with $SIND_IMAGE"
cat >"$OUT/cluster.yaml" <<EOF
kind: Cluster
defaults:
  image: $SIND_IMAGE
  cpus: 2
  memory: 3g
  tmpSize: 1g
  devices: [/dev/fuse]
  securityOpt: [seccomp=unconfined, apparmor=unconfined, systempaths=unconfined]
users:
  - alice
slurm:
  main: |
    TaskProlog=/data/spike/taskprolog.sh
    SlurmdLogFile=/var/log/slurmd.log
    SlurmdDebug=debug
  plugstack: |
    optional /usr/local/libexec/slurm-singularity-exec.so default= script=/usr/local/libexec/slurm-singularity-wrapper.sh bind=/etc/slurm,/var/run/munge,/var/spool/slurmd global= args=""
nodes:
  - role: controller
  - role: worker
    count: 2
EOF
"$SIND" create cluster --config "$OUT/cluster.yaml" 2>&1 | tee -a "$LOG" || exit 1
"$SIND" exec -- sinfo 2>&1 | tee -a "$LOG"
"$SIND" exec -- scontrol version 2>&1 | tee -a "$LOG"
log "config volume of worker-0: $(conf_volume sind-default-worker-0)"

###############################################################################
log "install Apptainer and the plugin on every node"
for n in "${NODES[@]}"; do
  on "$n" >>"$LOG" 2>&1 <<'EOF' &
set -x
dnf -y -q install apptainer squashfs-tools gcc-c++ libstdc++-static cmake make || dnf -y -q install gcc-c++ libstdc++-static cmake make
command -v apptainer || dnf -y -q install https://github.com/apptainer/apptainer/releases/download/v1.5.5/apptainer-1.5.5-1.x86_64.rpm
apptainer --version
cmake -S /data -B /tmp/build -DBUILD_TESTING=OFF --install-prefix /usr/local
cmake --build /tmp/build && cmake --install /tmp/build
ls -l /usr/local/libexec/
EOF
done
wait
for n in "${NODES[@]}"; do
  echo "echo $n: \$(apptainer --version 2>&1) \$(ls /usr/local/libexec/slurm-singularity-exec.so 2>&1)" | on "$n" | tee -a "$LOG"
done

log "build the test image"
echo "mkdir -p /var/tmp/ab && APPTAINER_TMPDIR=/var/tmp/ab apptainer build --force $SIF $SIF_SOURCE && ls -l $SIF" | on worker-0 >>"$LOG" 2>&1
echo "ls -l $SIF" | on worker-1 | tee -a "$LOG"

log "write the probe"
as_alice >>"$LOG" 2>&1 <<'EOS'
cat > /home/alice/probe.sh <<'P'
#!/bin/bash
printf "os=%s rank=%s tp=%s stack=%s weird=[%s] nslurm=%s cwd=%s\n" \
  "$(. /etc/os-release; echo $ID)" "${SLURM_PROCID:-unset}" "${TP_MARK:-unset}" \
  "$(ulimit -S -s)" "${WEIRD:-unset}" "$(env | grep -c ^SLURM_)" "$PWD"
P
chmod 755 /home/alice/probe.sh
EOS

log "sanity: Apptainer as alice directly on worker-0"
"$SIND" ssh alice@worker-0 -- apptainer exec "$SIF" cat /etc/os-release 2>&1 | head -3 | tee -a "$LOG"

###############################################################################
log "probes"

obs B1 "baseline, no container: srun -N2 -n2" <<EOF
$SUBMIT_ENV
srun -N2 -n2 $PROBE | sort
EOF

obs S0 "SPANK: srun --help lists plugin options" <<'EOF'
srun --help | grep -c -- '--singularity-'
EOF

obs S1 "SPANK: srun -N2 -n2 --singularity-container" <<EOF
$SUBMIT_ENV
srun -N2 -n2 --singularity-container=$SIF $PROBE 2>&1 | grep -v '^Start container' | sort
EOF

obs S2 "SPANK: --singularity-bind=/data/spike:/mnt/x" <<EOF
srun --singularity-container=$SIF --singularity-bind=/data/spike:/mnt/x ls /mnt/x 2>&1 | grep -c taskprolog
EOF

obs S3 "SPANK: --singularity-args=--cleanenv (user runtime flags)" <<EOF
export FOO=bar
srun --singularity-container=$SIF --singularity-args=--cleanenv bash -c 'echo FOO=\${FOO:-unset}' 2>&1 | grep FOO
EOF

obs S4 "SPANK: sbatch --singularity-container, batch script in container" <<EOF
$SUBMIT_ENV
cd /home/alice
sbatch --wait -o s4.out --singularity-container=$SIF --wrap '$PROBE; srun -n1 hostname' >/dev/null 2>&1
grep -v '^Start container' s4.out
EOF

obs S5 "SPANK: SLURM_SINGULARITY_CONTAINER env var" <<EOF
SLURM_SINGULARITY_CONTAINER=$SIF srun bash -c '. /etc/os-release; echo \$ID' 2>&1 | grep -v '^Start'
EOF

###############################################################################
log "native --container, variant N1: SchedMD Singularity example with apptainer"
write_oci_conf 'IgnoreFileConfigJson=true
EnvExclude="^(SLURM_CONF|SLURM_CONF_SERVER)="
RunTimeEnvExclude="^(SLURM_CONF|SLURM_CONF_SERVER)="
RunTimeRun="apptainer exec --userns %r %@"
RunTimeKill="kill -s SIGTERM %p"
RunTimeDelete="kill -s SIGKILL %p"'

obs N1 "native N1 (apptainer exec --userns %r %@): srun -N2 -n2 --container" <<EOF
$SUBMIT_ENV
srun -N2 -n2 --container=$SIF $PROBE 2>&1 | sort
EOF

obs N1b "native N1: sbatch --container, batch script in container" <<EOF
$SUBMIT_ENV
cd /home/alice
sbatch --wait -o n1b.out --container=$SIF --wrap '$PROBE' >/dev/null 2>&1
cat n1b.out
EOF

obs N1c "native N1: srun --help lists --container" <<'EOF'
srun --help | grep -c -- '--container'
EOF

obs N1d "native N1: SRUN_CONTAINER env var" <<EOF
SRUN_CONTAINER=$SIF srun bash -c '. /etc/os-release; echo \$ID' 2>&1
EOF

log "native --container, variant N2: environment file"
write_oci_conf 'IgnoreFileConfigJson=true
CreateEnvFile=newline
EnvExclude="^(SLURM_CONF|SLURM_CONF_SERVER)="
RunTimeEnvExclude="^(SLURM_CONF|SLURM_CONF_SERVER)="
RunTimeRun="apptainer exec --userns --cleanenv --env-file %e %r %@"
RunTimeKill="kill -s SIGTERM %p"
RunTimeDelete="kill -s SIGKILL %p"'

obs N2 "native N2 (--env-file %e): srun -N2 -n2 --container" <<EOF
$SUBMIT_ENV
srun -N2 -n2 --container=$SIF $PROBE 2>&1 | sort
EOF

obs N2b "native N2: sbatch --container, batch script in container" <<EOF
$SUBMIT_ENV
cd /home/alice
sbatch --wait -o n2b.out --container=$SIF --wrap '$PROBE' >/dev/null 2>&1
cat n2b.out
EOF

obs N2c "native N2: srun -N2 -n2 --container, no variable with quotes" <<EOF
ulimit -S -s 4096
srun -N2 -n2 --container=$SIF $PROBE 2>&1 | sort
EOF

log "native --container, variant N3: wrapper takes the NUL-separated env file"
for n in "${WORKERS[@]}"; do
  on "$n" >>"$LOG" 2>&1 <<'EOF'
cat > /usr/local/libexec/oci-apptainer-run <<'W'
#!/bin/bash
# oci.conf RunTimeRun wrapper: $1 image (%r), $2 NUL-separated job
# environment (%e), rest: command (%@). Runs Apptainer with exactly the job
# environment. Per-job bind paths come from SLURM_SINGULARITY_BIND.
img=$1 envf=$2; shift 2
mapfile -d '' vars < "$envf"
bind=/var/spool/slurmd
for kv in "${vars[@]}"; do
  case $kv in SLURM_SINGULARITY_BIND=?*) bind+=",${kv#*=}" ;; esac
done
exec /usr/bin/env -i "${vars[@]}" /usr/bin/apptainer exec --userns --bind "$bind" "$img" "$@"
W
chmod 755 /usr/local/libexec/oci-apptainer-run
EOF
done
write_oci_conf 'IgnoreFileConfigJson=true
CreateEnvFile=null
EnvExclude="^(SLURM_CONF|SLURM_CONF_SERVER)="
RunTimeEnvExclude="^(SLURM_CONF|SLURM_CONF_SERVER)="
RunTimeRun="/usr/local/libexec/oci-apptainer-run %r %e %@"
RunTimeKill="kill -s SIGTERM %p"
RunTimeDelete="kill -s SIGKILL %p"'

obs N3 "native N3 (wrapper, env-driven bind): SLURM_SINGULARITY_BIND=/data/spike:/mnt/x" <<EOF
SLURM_SINGULARITY_BIND=/data/spike:/mnt/x srun --container=$SIF ls /mnt/x 2>&1 | grep -c taskprolog
EOF

obs N3b "native N3: srun -N2 -n2 --container" <<EOF
$SUBMIT_ENV
srun -N2 -n2 --container=$SIF $PROBE 2>&1 | sort
EOF

obs N3c "native N3: sbatch --container, batch script in container" <<EOF
$SUBMIT_ENV
cd /home/alice
sbatch --wait -o n3c.out --container=$SIF --wrap '$PROBE; srun -n1 hostname' >/dev/null 2>&1
cat n3c.out
EOF

obs N3e "native N3: srun --container=/nonexistent.sif" <<EOF
srun --container=/nonexistent.sif true 2>&1 | head -3
EOF

obs X1 "both: --container and --singularity-container in one srun" <<EOF
srun --container=$SIF --singularity-container=$SIF bash -c '. /etc/os-release; echo \$ID; cat /proc/self/cgroup | head -1' 2>&1 | grep -v '^Start'
EOF

remove_oci_conf
obs X2 "no oci.conf on node: srun --container is advisory" <<EOF
srun --container=$SIF bash -c '. /etc/os-release; echo \$ID' 2>&1
EOF

log "slurmd log tail"
echo 'grep -E "error|container|oci|RunTime|apptainer|execve" /var/log/slurmd.log | grep -v "differs from hardware" | tail -250' | on worker-0 >>"$LOG" 2>&1

cat "$RES"
echo "::group::full log"
cat "$LOG"
echo "::endgroup::"
