#!/usr/bin/env bash
# One-command AWS test deploy of the LDR stack (AWS CLI v2 + ssh; Linux, macOS, Git Bash).
#
#   ./cloud.sh up      create key pair + security group (SSH from your IP only),
#                      launch the instance; user-data installs Docker, clones the
#                      repo and runs ./deploy.sh up
#   ./cloud.sh test    wait until the stack is ready, open an SSH tunnel, run one
#                      research through the web API, save timing + report in results/
#   ./cloud.sh down    terminate the instance, delete the key pair and security group
#   ./cloud.sh run     up + test + down (down ALWAYS runs, even on error)
#   ./cloud.sh tunnel  foreground tunnel for the demo: http://localhost:5001
#   ./cloud.sh status  show the instance and the estimated spend
#
# Cost guards: the instance terminates itself after MAX_HOURS (shutdown -h in
# user-data + instance-initiated-shutdown-behavior=terminate); `up` refuses to
# start if spend so far + MAX_HOURS at the hourly price would pass BUDGET_USD.
# Without GPU quota (G and VT vCPUs = 0) it falls back to a CPU instance.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1          # Git Bash: do not rewrite /paths in aws args

REGION="${REGION:-us-east-2}"       # only region allowed by the account's SCP
NAME="${NAME:-ldr-test}"
BUDGET_USD="${BUDGET_USD:-10}"
MAX_HOURS="${MAX_HOURS:-2}"
DISK_GB="${DISK_GB:-40}"
REPO_URL="${REPO_URL:-https://github.com/edumigueis/local-deep-research.git}"
BRANCH="${BRANCH:-main}"
QUERY="${QUERY:-What are the main differences between IaaS, PaaS and SaaS in cloud computing?}"
LOCAL_PORT="${LOCAL_PORT:-5001}"
STATE_DIR=".cloud"; STATE="$STATE_DIR/state"; COST_LOG="results/cost-log.csv"
KEY_FILE="$HOME/.ssh/${NAME}-key.pem"   # outside OneDrive so chmod 600 sticks

# On-demand Linux prices, us-east-2 (USD/hour) and gp3 storage (USD/GB-month).
price() { case "$1" in t3.xlarge) echo 0.1664;; t3.2xlarge) echo 0.3328;; g4dn.xlarge) echo 0.526;; g5.xlarge) echo 1.006;; *) echo "";; esac; }
GP3_GB_MONTH=0.08

log() { printf '\033[1;35m[cloud]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

if command -v aws >/dev/null; then AWS=aws
elif [[ -x "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]]; then AWS="/c/Program Files/Amazon/AWSCLIV2/aws.exe"
else err "AWS CLI v2 not found"; exit 1; fi
aws_() { "$AWS" --region "$REGION" "$@"; }
if command -v python3 >/dev/null && python3 -c 'import requests' 2>/dev/null; then PY=python3; else PY=python; fi

save() { mkdir -p "$STATE_DIR"; grep -v "^$1=" "$STATE" 2>/dev/null > "$STATE.tmp" || true; echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }
load() { grep -E "^$1=" "$STATE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

pick_instance() { # sets ITYPE, MODEL, GPU
  local q; q="$(aws_ service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
               --query 'Quota.Value' --output text 2>/dev/null || echo 0)"
  if [[ -n "${INSTANCE_TYPE:-}" ]]; then ITYPE="$INSTANCE_TYPE"
  elif awk "BEGIN{exit !($q >= 4)}"; then ITYPE=g4dn.xlarge
  else ITYPE=t3.xlarge; log "GPU quota is $q vCPU -> CPU fallback (t3.xlarge)"; fi
  if [[ "$ITYPE" == g* ]]; then GPU=true; MODEL="${MODEL:-gemma3:4b}"
  else GPU=false; MODEL="${MODEL:-qwen2.5:3b}"; fi
}

spent_so_far() { [[ -f "$COST_LOG" ]] && awk -F, 'NR>1{s+=$NF} END{printf "%.4f", s+0}' "$COST_LOG" || echo 0; }

budget_check() {
  local p spent worst; p="$(price "$ITYPE")"
  [[ -z "$p" ]] && { err "no price for $ITYPE; add it to price()"; exit 1; }
  spent="$(spent_so_far)"
  worst="$(awk -v s="$spent" -v p="$p" -v h="$MAX_HOURS" -v d="$DISK_GB" -v g="$GP3_GB_MONTH" \
           'BEGIN{printf "%.4f", s + p*h + d*g*h/730}')"
  log "Budget: \$$BUDGET_USD | spent so far (est.) \$$spent | worst case after this run \$$worst ($ITYPE @ \$$p/h x ${MAX_HOURS}h)"
  awk -v w="$worst" -v b="$BUDGET_USD" 'BEGIN{exit !(w <= b)}' || { err "would exceed budget, refusing"; exit 1; }
}

find_ami() {
  if $GPU; then # Docker + NVIDIA driver + container toolkit preinstalled
    aws_ ec2 describe-images --owners amazon \
      --filters 'Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*' 'Name=state,Values=available' \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
  else
    aws_ ec2 describe-images --owners 099720109477 \
      --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
  fi
}

user_data() {
  local gpuflag=""; $GPU && gpuflag="--gpu"
  cat <<EOF
#!/bin/bash
# Cost guard first: power off (=> terminate) after ${MAX_HOURS}h no matter what.
shutdown -h +$((MAX_HOURS*60))
set -eux
exec > /var/log/ldr-bootstrap.log 2>&1
date +%s > /var/lib/ldr-boot-start
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null; then
  apt-get update -y
  apt-get install -y docker.io docker-compose-v2 git
fi
docker compose version || { apt-get update -y; apt-get install -y docker-compose-v2 || apt-get install -y docker-compose-plugin; }
systemctl enable --now docker
git clone --depth 1 -b ${BRANCH} ${REPO_URL} /opt/ldr
cd /opt/ldr
cp .env.example .env
sed -i 's/^LDR_LLM_MODEL=.*/LDR_LLM_MODEL=${MODEL}/' .env
./deploy.sh up ${gpuflag}
date +%s > /var/lib/ldr-ready
EOF
}

cmd_up() {
  [[ -n "$(load INSTANCE_ID)" ]] && { err "instance $(load INSTANCE_ID) already in state; run ./cloud.sh down first"; exit 1; }
  pick_instance; budget_check
  local myip ami sg iid
  myip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  ami="$(find_ami)"; [[ "$ami" == ami-* ]] || { err "AMI not found"; exit 1; }
  log "Region $REGION | $ITYPE | model $MODEL | AMI $ami | SSH allowed from $myip/32"

  mkdir -p "$(dirname "$KEY_FILE")"; rm -f "$KEY_FILE"
  aws_ ec2 create-key-pair --key-name "$NAME-key" --key-type ed25519 \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"; save KEY_NAME "$NAME-key"

  sg="$(aws_ ec2 create-security-group --group-name "$NAME-sg" \
        --description "LDR test: SSH from operator IP only" --query GroupId --output text)"
  save SG_ID "$sg"
  aws_ ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$myip/32" >/dev/null

  mkdir -p "$STATE_DIR"; user_data > "$STATE_DIR/user-data.sh"
  iid="$(aws_ ec2 run-instances --image-id "$ami" --instance-type "$ITYPE" \
        --key-name "$NAME-key" --security-group-ids "$sg" \
        --instance-initiated-shutdown-behavior terminate \
        --metadata-options HttpTokens=required \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
        --user-data "file://$STATE_DIR/user-data.sh" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=ldr}]" \
        --query 'Instances[0].InstanceId' --output text)"
  save INSTANCE_ID "$iid"; save ITYPE "$ITYPE"; save MODEL "$MODEL"; save LAUNCHED "$(date +%s)"
  log "Launched $iid, waiting for 'running'..."
  aws_ ec2 wait instance-running --instance-ids "$iid"
  save IP "$(aws_ ec2 describe-instances --instance-ids "$iid" \
             --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  log "Running at $(load IP). Bootstrap takes ~5-10 min; then ./cloud.sh test"
}

ssh_() { ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o LogLevel=ERROR -o ConnectTimeout=10 "ubuntu@$(load IP)" "$@"; }

wait_ready() {
  local t0=$SECONDS
  log "Waiting for the stack on the instance (deploy.sh up)..."
  until ssh_ 'test -f /var/lib/ldr-ready' 2>/dev/null; do
    (( SECONDS - t0 > 1800 )) && { err "not ready after 30 min"; ssh_ 'sudo tail -n 40 /var/log/ldr-bootstrap.log' || true; return 1; }
    if ssh_ 'cloud-init status' 2>/dev/null | grep -q error; then
      err "cloud-init failed"; ssh_ 'sudo tail -n 40 /var/log/ldr-bootstrap.log' || true; return 1
    fi
    sleep 20
  done
  local b r; b="$(ssh_ cat /var/lib/ldr-boot-start)"; r="$(ssh_ cat /var/lib/ldr-ready)"
  save BOOTSTRAP_S "$((r-b))"
  log "Stack ready (bootstrap: install Docker + images + model = $((r-b)) s)"
}

cmd_test() {
  [[ -n "$(load INSTANCE_ID)" ]] || { err "no instance; run ./cloud.sh up"; exit 1; }
  wait_ready
  [[ -f .test-account ]] || printf 'LDR_TEST_USER=tester\nLDR_TEST_PASSWORD=Ldr-%s-9a\n' "$(date +%s%N | sha256sum | cut -c1-16)" > .test-account
  # shellcheck disable=SC1091
  . ./.test-account
  local out="results/aws-$(load ITYPE)" pid rc=0
  ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ExitOnForwardFailure=yes -N -L "$LOCAL_PORT:localhost:5000" "ubuntu@$(load IP)" &
  pid=$!; sleep 5
  "$PY" scripts/research_test.py --url "http://localhost:$LOCAL_PORT" \
      --user "$LDR_TEST_USER" --password "$LDR_TEST_PASSWORD" --query "$QUERY" \
      --out "$out" --label "AWS $(load ITYPE) $REGION $(load MODEL) bootstrap=$(load BOOTSTRAP_S)s" || rc=$?
  ssh_ 'cd /opt/ldr && sudo docker stats --no-stream; free -m; nproc' > "$out/instance-stats-$(date +%Y%m%d-%H%M%S).txt" 2>&1 || true
  kill "$pid" 2>/dev/null || true
  return $rc
}

cmd_tunnel() { log "Open http://localhost:$LOCAL_PORT (Ctrl-C to close)"; ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -N -L "$LOCAL_PORT:localhost:5000" "ubuntu@$(load IP)"; }

cmd_down() {
  local iid sg key it launched now hours cost
  iid="$(load INSTANCE_ID)"; sg="$(load SG_ID)"; key="$(load KEY_NAME)"
  if [[ -n "$iid" ]]; then
    log "Terminating $iid..."
    aws_ ec2 terminate-instances --instance-ids "$iid" >/dev/null || true
    aws_ ec2 wait instance-terminated --instance-ids "$iid" || true
    it="$(load ITYPE)"; launched="$(load LAUNCHED)"; now="$(date +%s)"
    hours="$(awk -v a="$launched" -v b="$now" 'BEGIN{printf "%.3f", (b-a)/3600}')"
    cost="$(awk -v h="$hours" -v p="$(price "$it")" -v d="$DISK_GB" -v g="$GP3_GB_MONTH" 'BEGIN{printf "%.4f", h*p + d*g*h/730}')"
    mkdir -p results; [[ -f "$COST_LOG" ]] || echo "date,instance_id,type,region,hours,usd_per_hour,est_cost_usd" > "$COST_LOG"
    echo "$(date +%F),$iid,$it,$REGION,$hours,$(price "$it"),$cost" >> "$COST_LOG"
    log "Ran ${hours} h -> est. \$$cost (total so far \$$(spent_so_far))"
  fi
  [[ -n "$sg" ]] && { aws_ ec2 delete-security-group --group-id "$sg" && log "Deleted SG $sg" || err "could not delete SG $sg"; }
  [[ -n "$key" ]] && { aws_ ec2 delete-key-pair --key-name "$key" >/dev/null && log "Deleted key pair $key"; rm -f "$KEY_FILE"; }
  rm -f "$STATE"
}

cmd_status() {
  local iid; iid="$(load INSTANCE_ID)"
  [[ -n "$iid" ]] && aws_ ec2 describe-instances --instance-ids "$iid" \
    --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,PublicIpAddress,LaunchTime]' --output table \
    || log "No instance in $STATE"
  log "Estimated spend so far: \$$(spent_so_far) of \$$BUDGET_USD"
}

cmd_run() {
  trap 'rc=$?; cmd_down; exit $rc' EXIT
  cmd_up; cmd_test
}

case "${1:-}" in
  up) cmd_up ;; test) cmd_test ;; down) cmd_down ;; run) cmd_run ;;
  tunnel) cmd_tunnel ;; status) cmd_status ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
