#!/usr/bin/env bash
# Teardown completo del lab EKS:
#   1) Vacía el repo ECR (terraform destroy de 25-ecr falla si quedan imágenes).
#   2) Borra recursos de Kubernetes que crean infra en AWS (Services LB, Ingresses)
#   3) Espera a que AWS termine de borrar los LBs
#   4) Recovery: limpia LBs y Security Groups huérfanos en la VPC
#   5) terraform destroy en orden inverso: 35-alb-controller -> 30-app-iam -> 25-ecr -> 20-eks -> 10-network
#
# Uso:
#   AWS_PROFILE=personal AWS_REGION=us-east-1 ./scripts/teardown.sh
#   ./scripts/teardown.sh --dry-run         # solo muestra qué haría
#   ./scripts/teardown.sh --skip-ecr-empty  # si ya sabes que el repo está vacío
#   ./scripts/teardown.sh --skip-k8s        # si ya no tenés acceso al cluster
#   ./scripts/teardown.sh --only-recovery   # solo limpia LBs/SGs huérfanos
# El stack 00-bootstrap (S3) NO se borra (cuesta centavos y guarda el state).
# Requiere: aws cli, terraform, kubectl, helm, jq

set -euo pipefail

# ---------- args ----------
DRY_RUN=0
SKIP_ECR_EMPTY=0
SKIP_K8S=0
ONLY_RECOVERY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --skip-ecr-empty) SKIP_ECR_EMPTY=1 ;;
    --skip-k8s)       SKIP_K8S=1 ;;
    --only-recovery)  ONLY_RECOVERY=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

# ---------- config ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_DIR="$REPO_ROOT/infra/aws/10-network"
EKS_DIR="$REPO_ROOT/infra/aws/20-eks"
ECR_DIR="$REPO_ROOT/infra/aws/25-ecr"
APP_IAM_DIR="$REPO_ROOT/infra/aws/30-app-iam"
ALB_CONTROLLER_DIR="$REPO_ROOT/infra/aws/35-alb-controller"
BACKEND_CONFIG="$REPO_ROOT/infra/aws/backend.hcl"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-hello-api}"
CLUSTER_NAME="${CLUSTER_NAME:-lab}"
export AWS_REGION
TFSTATE_BUCKET=""

# ---------- helpers ----------
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

step() { echo; c_blue "==> $*"; }
warn() { c_yellow "WARN: $*"; }
die()  { c_red "ERROR: $*"; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    c_yellow "[dry-run] $*"
  else
    eval "$@"
  fi
}

require() { command -v "$1" >/dev/null 2>&1 || die "falta comando: $1"; }

# ---------- preflight ----------
require aws
require terraform
require jq
[ "$SKIP_K8S" = "1" ] || { require kubectl; require helm; }

aws sts get-caller-identity >/dev/null || die "AWS no autenticado (revisá AWS_PROFILE / SSO)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
c_green "AWS profile=${AWS_PROFILE:-<default>} account=$ACCOUNT region=$AWS_REGION"

# Backend compartido (infra/aws/backend.hcl). Si existe, extraemos bucket para
# pasarlo como -var en stacks que lo necesitan (cuando no hay terraform.tfvars).
if [ -f "$BACKEND_CONFIG" ]; then
  TFSTATE_BUCKET="$(awk -F'"' '/^[[:space:]]*bucket[[:space:]]*=/ {print $2; exit}' "$BACKEND_CONFIG" || true)"
  [ -n "$TFSTATE_BUCKET" ] && c_green "Bucket de tfstate detectado: $TFSTATE_BUCKET"
else
  warn "No existe $BACKEND_CONFIG. Usaré init sin backend-config donde aplique."
fi

# Resolver VPC ID desde el state de 10-network (fallback: tag Name=lab-vpc).
# Solo aceptamos valores que empiecen con "vpc-" para evitar warnings de terraform.
VPC_ID=""
if [ -d "$NETWORK_DIR/.terraform" ]; then
  CANDIDATE="$(terraform -chdir="$NETWORK_DIR" output -raw vpc_id 2>/dev/null || true)"
  [[ "$CANDIDATE" =~ ^vpc-[a-f0-9]+$ ]] && VPC_ID="$CANDIDATE"
fi
if [ -z "$VPC_ID" ]; then
  CANDIDATE="$(aws ec2 describe-vpcs \
    --filters Name=tag:Name,Values=lab-vpc \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  [[ "$CANDIDATE" =~ ^vpc-[a-f0-9]+$ ]] && VPC_ID="$CANDIDATE"
fi
if [ -n "$VPC_ID" ]; then
  c_green "VPC del lab: $VPC_ID"
else
  warn "No encontré la VPC del lab (¿ya destruida?). Solo voy a limpiar K8s + correr destroys."
fi

# ===========================================================================
# 1) Vaciar repo ECR (25-ecr destroy falla si quedan imágenes, salvo
#    force_delete=true; lo hacemos explícito para un teardown de laboratorio)
# ===========================================================================
if [ "$ONLY_RECOVERY" = "0" ] && [ "$SKIP_ECR_EMPTY" = "0" ]; then
  step "1) Vaciando repo ECR '$ECR_REPO_NAME' (si existe)"
  if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    while true; do
      IMG_IDS="$(aws ecr list-images --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" \
        --query 'imageIds[*]' --output json)"
      COUNT="$(echo "$IMG_IDS" | jq 'length')"
      if [ "$COUNT" -eq 0 ]; then
        c_green "Repo ECR ya está vacío"
        break
      fi

      warn "Hay $COUNT imágenes en $ECR_REPO_NAME — borrándolas en lotes de 100"
      while IFS= read -r BATCH; do
        [ -z "$BATCH" ] && continue
        run "aws ecr batch-delete-image --region '$AWS_REGION' --repository-name '$ECR_REPO_NAME' --image-ids '$BATCH' >/dev/null"
      done < <(echo "$IMG_IDS" | jq -c 'def chunks(n): [range(0; length; n) as $i | .[$i:$i+n]]; chunks(100)[]')
    done
  else
    c_green "Repo ECR no existe (ya destruido o nunca creado)"
  fi
fi

# ===========================================================================
# 2) Limpieza de Kubernetes (libera LBs/EBS administrados por el cluster)
# ===========================================================================
if [ "$SKIP_K8S" = "0" ] && [ "$ONLY_RECOVERY" = "0" ]; then
  step "2) Borrando recursos de Kubernetes con efectos en AWS"

  if ! kubectl cluster-info >/dev/null 2>&1; then
    warn "kubectl no puede contactar al cluster (kubeconfig?). Salteando paso 1."
    warn "Si el cluster aún existe, abortá y arreglá el kubeconfig:"
    warn "  aws eks update-kubeconfig --name <cluster> --region $AWS_REGION"
  else
    run "helm uninstall hello-api -n hello 2>/dev/null || true"
    run "kubectl delete svc -A --field-selector spec.type=LoadBalancer --ignore-not-found --timeout=120s || true"
    run "kubectl delete ingress -A --all --ignore-not-found --timeout=120s || true"
    run "kubectl delete ns hello --ignore-not-found --timeout=120s || true"

    step "Esperando que AWS termine de borrar los LBs creados por el cluster (hasta 3 min)..."
    if [ "$DRY_RUN" = "0" ] && [ -n "$VPC_ID" ]; then
      for i in $(seq 1 18); do
        CLB=$(aws elb describe-load-balancers --region "$AWS_REGION" \
              --query "length(LoadBalancerDescriptions[?VPCId=='$VPC_ID'])" --output text 2>/dev/null || echo 0)
        ALB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
              --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text 2>/dev/null || echo 0)
        echo "  [$i/18] LBs en la VPC -> classic=$CLB v2=$ALB"
        if [ "$CLB" = "0" ] && [ "$ALB" = "0" ]; then break; fi
        sleep 10
      done
    fi
  fi
fi

# ===========================================================================
# 3) Recovery: borrar LBs huérfanos en la VPC (si quedaron)
# ===========================================================================
if [ -n "$VPC_ID" ]; then
  step "2) Buscando LBs huérfanos en $VPC_ID"

  ORPHAN_CLB=$(aws elb describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || true)
  ORPHAN_ALB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true)

  if [ -n "$ORPHAN_CLB" ]; then
    warn "Classic ELBs huérfanos: $ORPHAN_CLB"
    for name in $ORPHAN_CLB; do
      run "aws elb delete-load-balancer --region $AWS_REGION --load-balancer-name $name"
    done
  fi
  if [ -n "$ORPHAN_ALB" ]; then
    warn "ALB/NLB huérfanos: $ORPHAN_ALB"
    for arn in $ORPHAN_ALB; do
      run "aws elbv2 delete-load-balancer --region $AWS_REGION --load-balancer-arn $arn"
    done
  fi

  step "Esperando que desaparezcan ENIs de Load Balancers (hasta 2 min)"
  if [ "$DRY_RUN" = "0" ]; then
    for i in $(seq 1 12); do
      N=$(aws ec2 describe-network-interfaces \
            --filters Name=vpc-id,Values="$VPC_ID" \
            --query "length(NetworkInterfaces[?contains(Description, 'ELB') || RequesterId=='amazon-elb'])" \
            --output text 2>/dev/null || echo 0)
      echo "  [$i/12] ENIs de LB restantes en la VPC: $N"
      if [ "$N" = "0" ]; then break; fi
      sleep 10
    done
    if [ "$N" != "0" ]; then
      warn "Aún hay $N ENIs de LB en la VPC. Detalle:"
      aws ec2 describe-network-interfaces --filters Name=vpc-id,Values="$VPC_ID" \
        --query "NetworkInterfaces[?contains(Description, 'ELB') || RequesterId=='amazon-elb'].[NetworkInterfaceId,Description,Status,RequesterId]" \
        --output table || true
      die "Resolvé las ENIs de LB restantes a mano antes de seguir (ver ROADMAP §7.6.B)."
    fi
  fi

  # Security Groups huérfanos creados por kube-controller-manager (k8s-elb-*).
  # AWS NO los borra al borrar el ELB; quedan dentro de la VPC y bloquean el
  # destroy del aws_vpc con DependencyViolation silencioso (cuelga indefinido).
  step "Buscando Security Groups huérfanos (k8s-*) en la VPC"
  ORPHAN_SGS=$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values="$VPC_ID" "Name=group-name,Values=k8s-*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)
  if [ -n "$ORPHAN_SGS" ]; then
    warn "SGs huérfanos detectados: $ORPHAN_SGS"
    for sg in $ORPHAN_SGS; do
      run "aws ec2 delete-security-group --region $AWS_REGION --group-id $sg || warn 'No se pudo borrar $sg (¿aún en uso?)'"
    done
  else
    echo "  (ninguno)"
  fi
fi

[ "$ONLY_RECOVERY" = "1" ] && { c_green "Recovery completo. Saliendo (--only-recovery)."; exit 0; }

# ===========================================================================
# 4) Terraform destroy en orden inverso
# ===========================================================================
destroy_stack() {
  local dir="$1" label="$2"
  local destroy_cmd=""
  if [ ! -d "$dir" ]; then warn "no existe $dir, skip"; return 0; fi
  step "4.$label) terraform destroy en $dir"
  if [ ! -d "$dir/.terraform" ]; then
    if [ ! -f "$BACKEND_CONFIG" ]; then
      die "No existe $BACKEND_CONFIG. Crealo desde infra/aws/backend.hcl.example antes de correr teardown."
    fi
    run "terraform -chdir='$dir' init -backend-config='$BACKEND_CONFIG' -reconfigure"
  fi
  destroy_cmd="terraform -chdir='$dir' destroy -auto-approve"

  # Si faltan tfvars locales, inyectamos variables mínimas para stacks dependientes.
  if [ -z "${TF_VAR_tfstate_bucket:-}" ] && [ -n "$TFSTATE_BUCKET" ] && [ ! -f "$dir/terraform.tfvars" ]; then
    if [ "$dir" = "$EKS_DIR" ] || [ "$dir" = "$APP_IAM_DIR" ] || [ "$dir" = "$ALB_CONTROLLER_DIR" ]; then
      destroy_cmd="$destroy_cmd -var tfstate_bucket=$TFSTATE_BUCKET"
    fi
  fi

  if [ -z "${TF_VAR_cluster_name:-}" ] && [ ! -f "$dir/terraform.tfvars" ]; then
    if [ "$dir" = "$APP_IAM_DIR" ] || [ "$dir" = "$ALB_CONTROLLER_DIR" ]; then
      destroy_cmd="$destroy_cmd -var cluster_name=$CLUSTER_NAME"
    fi
  fi

  run "$destroy_cmd"
}

destroy_stack "$ALB_CONTROLLER_DIR" "a 35-alb-controller"
destroy_stack "$APP_IAM_DIR"        "b 30-app-iam"
destroy_stack "$ECR_DIR"            "c 25-ecr"
destroy_stack "$EKS_DIR"            "d 20-eks (~10 min)"
destroy_stack "$NETWORK_DIR"        "e 10-network"

step "Listo."
c_green "Teardown completo. Bootstrap (00-bootstrap) intacto a propósito (S3 cuesta centavos)."
c_green "Si querés borrarlo también: cd infra/aws/00-bootstrap && terraform destroy"
