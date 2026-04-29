# my-aws-eks-lab — FastAPI en EKS desde Minikube

> Proyecto de aprendizaje: una API "hello world" en Python (FastAPI) que crece desde un cluster local en Colima/minikube hasta correr en EKS con el mismo Helm chart.
>
> **Fecha del plan:** Abril 2026 — todas las versiones revisadas a esta fecha.

---

## 0. Decisiones de stack y versiones

### Versiones fijadas

| Componente | Versión | Fuente |
|---|---|---|
| Kubernetes | **1.35.1** | minikube v1.38.1 soporta hasta 1.35.1; EKS soporta 1.35 desde 27-ene-2026 |
| minikube | v1.38.1 | https://github.com/kubernetes/minikube/releases |
| Helm | v3.18.x (no v4 todavía) | v4 rompe charts; postergar |
| Colima | latest brew | macOS host runtime |
| Python | 3.13 | sweet spot ecosistema |
| FastAPI | 0.136.1 | https://pypi.org/project/fastapi/ |
| uvicorn | 0.46.0 | https://uvicorn.dev/release-notes/ |
| Terraform | >= 1.6 | |
| terraform-aws-modules/eks | ~> 21.18 | v21.18.0 (13-abr-2026) |
| terraform-aws-modules/vpc | ~> 6.6 | v6.6.1 (2-abr-2026) |
| metrics-server (chart) | 3.13.0 / app 0.8.1 | addon del cluster |

### Decisiones arquitectónicas

| Decisión | Motivo |
|---|---|
| **EKS Pod Identity** (no IRSA) | Pattern moderno; sin OIDC trust ni annotations en el SA. |
| **Helm v3** (no v4) | v4 introduce breaking changes (`helm install` no espera, SSA por default, flags removidos). |
| **Bottlerocket AMI x86_64 (`t3.micro`)** | Baseline Free Tier estricto y más alineado a workloads amd64 de producción. Trade-off: capacidad limitada de pods/addons en single-node. |
| **K8s 1.35.1 fijo** | Paridad minikube↔EKS. No usar 1.35.2/3 hasta que minikube los soporte. |
| **`containerd` runtime + cgroup v2** | Requisito de K8s 1.35 (cgroup v1 removido). |
| **NAT Gateway + Gateway endpoint (S3)** | El endpoint de S3 es **gratis** y reduce ~80% del tráfico de NAT (ECR vive sobre S3). Alternativa más barata: `fck-nat` (~$5/mes) — ver Fase 5. |
| **Single-node `t3.micro`** | Free Tier estricto para lab efímero. Sirve para hello-world + pocos addons; al sumar addons puede aparecer `Too many pods`. |
| **ALB como camino de exposición** | Patrón más común en producción para HTTP/L7 (host/path routing, TLS con ACM, integración Ingress). |

---

## 1. Estructura del repo

```
my-aws-eks-lab/
├── README.md
├── ROADMAP.md                        # este archivo
├── .gitignore
├── app/                              # API Python
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── src/hello/main.py
│   └── tests/test_hello.py
├── charts/
│   └── hello-api/                    # Helm chart
│       ├── Chart.yaml
│       ├── values.yaml               # defaults
│       ├── values-minikube.yaml
│       ├── values-eks.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── serviceaccount.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── tests/test-connection.yaml
└── infra/
    └── aws/
        ├── backend.hcl.example        # copiar a backend.hcl (único para todos los stacks)
        ├── 00-bootstrap/             # state remoto (S3)
        ├── 10-network/               # VPC
        ├── 20-eks/                   # cluster + node group + addons del control plane
        ├── 25-ecr/                   # ECR de hello-api (repo + lifecycle policy)
        ├── 30-app-iam/               # rol IAM + Pod Identity Association de hello-api
        └── 35-alb-controller/        # AWS Load Balancer Controller (Terraform + Helm)
```

---

## 2. Fase 0 — Setup local (Colima)

**Objetivo:** Tener todas las herramientas y el daemon Docker (Colima) funcionando.

### Pasos

```bash
# 0.1 Instalar tooling
brew install colima docker docker-buildx kubectl helm minikube \
  awscli terraform kubectx k9s yq jq

# 0.2 Asegúrate de NO tener Docker Desktop activo (pelean por el socket)
# Si lo tienes, deshabilita su autostart o desinstálalo.

# 0.3 Levantar Colima con recursos para alojar minikube adentro
colima start --cpus 4 --memory 8 --disk 60

# 0.4 Verificar Docker context apunta a Colima
docker context use colima
docker info | grep -i name        # debe decir colima
docker run --rm hello-world

# 0.5 Crear repo
mkdir -p ~/projects/my-aws-eks-lab && cd ~/projects/my-aws-eks-lab
git init
cat > .gitignore <<'EOF'
.terraform/
*.tfstate*
*.tfvars
.env
__pycache__/
*.pyc
.venv/
.DS_Store
EOF
```

### Validación

```bash
docker info >/dev/null && echo "✅ docker"
kubectl version --client && echo "✅ kubectl"
helm version && echo "✅ helm"
minikube version && echo "✅ minikube"
terraform version && echo "✅ terraform"
aws --version && echo "✅ aws"
```

### Commit
```
chore: project bootstrap with .gitignore
```

---

## 3. Fase 1 — App Python + Docker

**Objetivo:** API FastAPI con `/`, `/healthz`, `/readyz` corriendo en un contenedor.

### Pasos

```bash
mkdir -p app/src/hello app/tests
```

**`app/src/hello/__init__.py`** (vacío)

**`app/src/hello/main.py`**:
```python
import os
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def hello():
    return {"message": "hello world", "env": os.getenv("APP_ENV", "local")}

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.get("/readyz")
def readyz():
    return {"ok": True}
```

**`app/pyproject.toml`**:
```toml
[project]
name = "hello-api"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
  "fastapi==0.136.1",
  "uvicorn[standard]==0.46.0",
]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools.packages.find]
where = ["src"]
```

**`app/tests/test_hello.py`**:
```python
from fastapi.testclient import TestClient
from hello.main import app

client = TestClient(app)

def test_hello():
    r = client.get("/")
    assert r.status_code == 200
    assert r.json()["message"] == "hello world"

def test_healthz():
    assert client.get("/healthz").json() == {"ok": True}
```

**`app/Dockerfile`**:
```dockerfile
FROM python:3.13-slim AS base
WORKDIR /app
COPY pyproject.toml ./
RUN pip install --no-cache-dir fastapi==0.136.1 'uvicorn[standard]==0.46.0'

FROM base
COPY src ./src
RUN useradd -u 10001 -m app && chown -R app:app /app
USER 10001
ENV PYTHONPATH=/app/src
EXPOSE 8080
CMD ["uvicorn", "hello.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

### Comandos

```bash
# Probar local sin Docker
cd app
python3 -m venv .venv && source .venv/bin/activate
pip install -e . pytest httpx
python -m pytest -q
uvicorn hello.main:app --host 0.0.0.0 --port 8080 &
curl localhost:8080/healthz
kill %1
deactivate
cd ..

# Probar con Docker
# Build amd64 explícito (alineado con el node group x86_64 de EKS)
docker-buildx build --platform linux/amd64 --load -t hello-api:0.1.0 app/
docker run --rm -d -p 8080:8080 --name hello hello-api:0.1.0
curl localhost:8080/
curl localhost:8080/healthz
docker rm -f hello
```

### Validación
- `pytest` pasa.
- `curl localhost:8080/healthz` desde el contenedor devuelve `{"ok":true}`.

### Commit
```
feat(app): hello-api fastapi with healthz and dockerfile
```

---

## 4. Fase 2 — Minikube + Helm chart

**Objetivo:** Cluster local con minikube y chart de Helm que deploya la app.

### Levantar minikube

```bash
minikube start \
  --driver=docker \
  --cpus=2 \
  --memory=4096 \
  --kubernetes-version=v1.35.1 \
  --container-runtime=containerd

minikube addons enable metrics-server
minikube addons enable ingress

kubectl get nodes
```

### Build de imagen accesible desde el cluster

Opción A — `minikube image load` (más simple):
```bash
# Para minikube local, construí en la arquitectura local del nodo.
# El build amd64 para EKS se hace en Fase 6.2.
docker build -t hello-api:0.1.0 app/
minikube image load hello-api:0.1.0
```

Opción B — `docker-env` (más rápido en iteraciones):
```bash
eval $(minikube docker-env)
# Igual que Opción A: build nativo del nodo minikube.
docker build -t hello-api:0.1.0 app/
eval $(minikube docker-env --unset)
```

### Crear el chart

```bash
mkdir -p charts/hello-api/templates/tests
```

**`charts/hello-api/Chart.yaml`**:
```yaml
apiVersion: v2
name: hello-api
description: Cloud-agnostic hello API
type: application
version: 0.1.0
appVersion: "0.1.0"
```

**`charts/hello-api/values.yaml`** (defaults):
```yaml
replicas: 2

image:
  repository: hello-api
  tag: "0.1.0"
  pullPolicy: IfNotPresent

env:
  APP_ENV: "default"

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 128Mi }

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: false
  className: ""
  host: ""
  annotations: {}
  tls: []

serviceAccount:
  create: true
  name: ""
  annotations: {}                # extender por cloud (Workload Identity, etc.)

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

pdb:
  enabled: true
  maxUnavailable: 1

topologySpread:
  enabled: false                 # off en cluster de 1 nodo

nodeSelector: {}
tolerations: []
```

**`charts/hello-api/values-minikube.yaml`**:
```yaml
replicas: 1
image:
  pullPolicy: Never
env:
  APP_ENV: "minikube"
ingress:
  enabled: true
  className: "nginx"
  host: "hello.local"
pdb:
  enabled: false
```

**`charts/hello-api/templates/_helpers.tpl`**:
```
{{- define "hello-api.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-api.labels" -}}
app.kubernetes.io/name: hello-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "hello-api.selectorLabels" -}}
app.kubernetes.io/name: hello-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "hello-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "hello-api.fullname" .)) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
```

**`charts/hello-api/templates/serviceaccount.yaml`**:
```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "hello-api.serviceAccountName" . }}
  labels: {{- include "hello-api.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations: {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
```

**`charts/hello-api/templates/deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "hello-api.fullname" . }}
  labels: {{- include "hello-api.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels: {{- include "hello-api.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "hello-api.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "hello-api.serviceAccountName" . }}
      securityContext: {{- toYaml .Values.podSecurityContext | nindent 8 }}
      {{- if .Values.topologySpread.enabled }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: {{- include "hello-api.selectorLabels" . | nindent 14 }}
      {{- end }}
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
          env:
            {{- range $k, $v := .Values.env }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 30
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 10
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            failureThreshold: 30
          resources: {{- toYaml .Values.resources | nindent 12 }}
          securityContext: {{- toYaml .Values.securityContext | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
      {{- with .Values.nodeSelector }}
      nodeSelector: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations: {{- toYaml . | nindent 8 }}
      {{- end }}
```

**`charts/hello-api/templates/service.yaml`**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "hello-api.fullname" . }}
  labels: {{- include "hello-api.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector: {{- include "hello-api.selectorLabels" . | nindent 4 }}
```

**`charts/hello-api/templates/ingress.yaml`**:
```yaml
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "hello-api.fullname" . }}
  labels: {{- include "hello-api.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations: {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "hello-api.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
  {{- with .Values.ingress.tls }}
  tls: {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
```

**`charts/hello-api/templates/pdb.yaml`**:
```yaml
{{- if .Values.pdb.enabled -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "hello-api.fullname" . }}
  labels: {{- include "hello-api.labels" . | nindent 4 }}
spec:
  maxUnavailable: {{ .Values.pdb.maxUnavailable }}
  selector:
    matchLabels: {{- include "hello-api.selectorLabels" . | nindent 6 }}
{{- end -}}
```

**`charts/hello-api/templates/hpa.yaml`**:
```yaml
{{- if .Values.autoscaling.enabled -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "hello-api.fullname" . }}
  labels: {{- include "hello-api.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "hello-api.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end -}}
```

**`charts/hello-api/templates/tests/test-connection.yaml`**:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "hello-api.fullname" . }}-test"
  labels: {{- include "hello-api.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ['curl']
      args:
        - '-fsS'
        - 'http://{{ include "hello-api.fullname" . }}/healthz'
```

### Lint, dry-run, install

```bash
helm lint charts/hello-api -f charts/hello-api/values-minikube.yaml
helm template charts/hello-api -f charts/hello-api/values-minikube.yaml | less

helm upgrade --install hello-api charts/hello-api \
  -f charts/hello-api/values-minikube.yaml \
  --namespace hello --create-namespace \
  --wait

kubectl get all -n hello
helm test hello-api -n hello
```

### Acceder

Opción simple — port-forward:
```bash
kubectl port-forward -n hello svc/hello-api 8080:80
curl localhost:8080/healthz
```

Opción cloud-like — minikube tunnel + ingress:
```bash
# Terminal 1 (dejala abierta):
minikube tunnel

# Terminal 2:
echo "127.0.0.1 hello.local" | sudo tee -a /etc/hosts
curl http://hello.local/healthz
```

### Validación
- `helm test hello-api -n hello` exitoso.
- `curl` a la app devuelve `{"ok":true}`.

### Commit
```
feat(chart): hello-api helm chart with minikube values
```

---

## 5. Fase 3 — Pulir el chart

**Objetivo:** Chart listo para cualquier cluster: HPA activo, lint en CI, helm test.

### Pasos

1. Activar HPA y validar:
   ```bash
   helm upgrade hello-api charts/hello-api \
     -f charts/hello-api/values-minikube.yaml \
     --set autoscaling.enabled=true \
     --set replicas=2 \
     -n hello
   kubectl get hpa -n hello
   ```

2. Carga sintética para ver scale:
   ```bash
   kubectl run -i --tty load-gen --rm --image=busybox --restart=Never -- \
     /bin/sh -c "while sleep 0.01; do wget -qO- http://hello-api.hello/; done"
   # en otra terminal:
   kubectl get hpa -n hello -w
   ```

3. (Opcional) GitHub Actions con `helm lint`:

   **`.github/workflows/chart-lint.yml`**:
   ```yaml
   name: chart-lint
   on: [pull_request]
   jobs:
     lint:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: azure/setup-helm@v4
           with: { version: v3.18.0 }
         - run: helm lint charts/hello-api -f charts/hello-api/values.yaml
         - run: helm lint charts/hello-api -f charts/hello-api/values-minikube.yaml
   ```

### Validación
- `kubectl get hpa -n hello` muestra el HPA y el `TARGETS` con uso real.
- `helm lint` con todos los `values-*.yaml` pasa.

### Commit
```
feat(chart): hpa enabled in defaults; ci lint workflow
```

---

## 6. Fase 4 — Terraform bootstrap (AWS state)

**Objetivo:** Bucket S3 versionado para state remoto (locking nativo por lockfile en S3). Una sola vez.

### Pasos

```bash
aws configure --profile personal       # access key + secret + región us-east-1
export AWS_PROFILE=personal
aws sts get-caller-identity
mkdir -p infra/aws/00-bootstrap
```

**`infra/aws/00-bootstrap/main.tf`**:
```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "aws_caller_identity" "me" {}

resource "aws_s3_bucket" "tfstate" {
  bucket        = "tfstate-my-k8s-lab-${data.aws_caller_identity.me.account_id}-us-east-1"
  force_destroy = true   # si no: terraform destroy falla con BucketNotEmpty (versiones del state)
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket" { value = aws_s3_bucket.tfstate.bucket }
```

```bash
cd infra/aws/00-bootstrap
terraform init
terraform apply
cd ../../..
```

### Validación
- `aws s3 ls | grep tfstate-my-k8s-lab-` muestra tu bucket.

### Destroy del bootstrap

Si `terraform destroy` falla con **`BucketNotEmpty`** / *You must delete all versions*, es porque el bucket tiene **versionado**: los `.tfstate` antiguos siguen ahí como versiones S3. El recurso `aws_s3_bucket` debe tener **`force_destroy = true`** para que Terraform borre todas las versiones antes de `DeleteBucket`.

Si ya corriste un destroy a medias (quedó el bucket pero no termina de borrar):

1. Actualizá `main.tf` con `force_destroy = true` (ya está en el repo).
2. `terraform apply` en `00-bootstrap` — asegura `force_destroy = true` en el bucket.
3. `terraform destroy`.

Alternativa manual para vaciar el bucket sin Terraform: `aws s3 rb s3://tfstate-my-k8s-lab-<ACCOUNT>-us-east-1 --force` (CLI v2 borra objetos y versiones).

### Commit
```
feat(infra): aws terraform bootstrap (s3 state backend)
```

---

## 7. Fase 5 — VPC + EKS 1.35 + ECR

**Objetivo:** dejar base de infraestructura lista con VPC, cluster EKS 1.35 (nodegroup Bottlerocket x86_64 `t3.micro` con `desired_size=3`) y repositorio ECR gestionado por Terraform.

> **Costo:** ~73 USD/mes control plane + cómputo en Free Tier mientras no superes 750 horas/mes agregadas de `t3.micro` + ~32 USD NAT (alternativa fck-nat: ~$5). **`terraform destroy`** cuando no uses para evitar el cargo del control plane (~$0.10/hora). En sesiones de 10 hrs/semana → ~$5-10/mes total.

### 5.1 Network

**`infra/aws/10-network/main.tf`**:
```hcl
terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key            = "10-network/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "aws_caller_identity" "me" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "lab-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true                # ahorro en lab

  public_subnet_tags  = { "kubernetes.io/role/elb"          = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# Gateway endpoint S3: gratis, reduce ~80% del tráfico de NAT (ECR vive sobre S3).
# En v6.x del módulo VPC los endpoints viven en un sub-módulo separado.
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.6"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "lab-s3-endpoint" }
    }
  }
}

# Alternativa más barata al NAT Gateway (~$5/mes vs $32):
# Reemplazá `enable_nat_gateway = true` por una NAT instance con fck-nat.
# Ver: https://github.com/RaJiska/terraform-aws-fck-nat
# Para lab está perfecto; para prod tiene SPOF.

output "vpc_id"          { value = module.vpc.vpc_id }
output "private_subnets" { value = module.vpc.private_subnets }
output "public_subnets"  { value = module.vpc.public_subnets }
```

**`infra/aws/backend.hcl`** (archivo único compartido por `10-network`, `20-eks`, `25-ecr`, `30-app-iam`, `35-alb-controller`):
```hcl
bucket = "tfstate-my-k8s-lab-<TU_ACCOUNT_ID>-us-east-1"
```

```bash
cd infra/aws
cp backend.hcl.example backend.hcl
cd ../..

cd infra/aws/10-network
terraform init -backend-config=../backend.hcl
terraform apply
cd ../../..
```

### 5.2 EKS

**`infra/aws/20-eks/main.tf`**:
```hcl
terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key            = "20-eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "10-network/terraform.tfstate"
    region = "us-east-1"
  }
}

variable "tfstate_bucket" { type = string }

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.18"

  name               = "lab"
  kubernetes_version = "1.35"

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_irsa = false                       # usamos Pod Identity

  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnets

  addons = {
    # before_compute = true: instalar antes del node group para que los nodos
    # tengan CNI y kube-proxy disponibles al joinear (sin esto, fallan con
    # NodeCreationFailure porque no pueden asignar IP a los system pods).
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      before_compute = true
      most_recent    = true
    }
    # t3.micro tiene presupuesto de pods/IPs muy bajo; forzamos CoreDNS a 1 réplica
    # para evitar Pending con "Too many pods" en lab single-node.
    coredns = {
      configuration_values = jsonencode({
        replicaCount = 1
      })
    }
    eks-pod-identity-agent = {}
    # En t3.micro el presupuesto de pods/IPs por nodo es bajo; dejamos metrics-server
    # fuera por default para mantener el lab estable.
    # metrics-server         = {}
    # aws-ebs-csi-driver omitido: no lo necesitamos para hello-world (sin PVCs)
    # y con desired_size=1 sus 2 réplicas HA se quedan Pending por anti-affinity.
    # Si en el futuro agregas PVCs/StatefulSets, descomenta con replicaCount=1:
    #   aws-ebs-csi-driver = {
    #     configuration_values = jsonencode({ controller = { replicaCount = 1 } })
    #   }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "BOTTLEROCKET_x86_64"   # amd64 para compatibilidad production-like
      instance_types = ["t3.micro"]            # Free Tier estricto en 2026
      min_size       = 3
      max_size       = 3
      desired_size   = 3                       # fijo en 3 para evitar "Too many pods" con ALB
    }
  }

  # Access entries: declara explícitamente qué IAM principals son admin del cluster.
  # Sin esto, ni siquiera quien crea el cluster tiene acceso vía kubectl.
  access_entries = {
    creator = {
      principal_arn = coalesce(var.cluster_admin_arn, data.aws_caller_identity.me.arn)
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

data "aws_caller_identity" "me" {}

variable "cluster_admin_arn" {
  description = "IAM principal ARN that gets cluster admin (defaults to caller)"
  type        = string
  default     = null
}

output "cluster_name"             { value = module.eks.cluster_name }
output "cluster_endpoint"         { value = module.eks.cluster_endpoint }
output "cluster_ca"               { value = module.eks.cluster_certificate_authority_data }
output "node_security_group_id"   { value = module.eks.node_security_group_id }
```

**`infra/aws/20-eks/terraform.tfvars`**:
```hcl
tfstate_bucket = "tfstate-my-k8s-lab-<TU_ACCOUNT_ID>-us-east-1"
```

```bash
cd infra/aws/20-eks
terraform init -backend-config=../backend.hcl
terraform apply   # ~15-20 min

aws eks update-kubeconfig --name lab --region us-east-1
kubectl get nodes
cd ../../..
```

### 5.3 ECR (Terraform, no manual)

**`infra/aws/25-ecr/main.tf`**:
```hcl
terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key          = "25-ecr/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

resource "aws_ecr_repository" "hello_api" {
  name                 = "hello-api"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "hello_api" {
  repository = aws_ecr_repository.hello_api.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_url" { value = aws_ecr_repository.hello_api.repository_url }
```

```bash
cd infra/aws/25-ecr
terraform init -backend-config=../backend.hcl
terraform apply
cd ../../..
```

### Validación
- `kubectl get nodes` muestra 3 nodos `Ready` (baseline para evitar `Too many pods`).
- `kubectl get pods -A` muestra coredns, kube-proxy, vpc-cni y pod-identity-agent `Running`.
- `terraform -chdir=infra/aws/25-ecr output -raw repository_url` devuelve el repo de ECR.

> **Nota capacidad (`t3.micro`)**: en `desired_size=1` el límite de pods/IP por nodo es muy ajustado y puede romper con addons base. Por eso este roadmap usa `desired_size=3`. Si igual te quedas corto, sube a `t3.small`.

### Commit
```
feat(infra): aws vpc eks and ecr terraform stacks
```

---

## 8. Fase 6 — Pod Identity + Deploy hello-api a EKS

**Objetivo:** crear el rol IAM de la app vía Pod Identity, buildear y pushear la imagen a ECR, instalar el chart con `values-eks.yaml`, exponer vía ALB (Ingress), y validar HTTP público.

### 6.1 Pod Identity Association

**`infra/aws/30-app-iam/main.tf`:** ya está creado en el repo, solo aplicar.

```bash
cd infra/aws/30-app-iam
cp terraform.tfvars.example terraform.tfvars    # editar con tu ACCOUNT_ID
terraform init -backend-config=../backend.hcl
terraform apply
cd ../../..
```

**Verificación:**

```bash
aws eks list-pod-identity-associations --cluster-name lab
# Debe listar el SA hello-api-sa en el namespace hello, asociado al rol hello-api.
```

### 6.2 Push de la imagen a ECR (repo creado con Terraform)

```bash
REGION=us-east-1
REPO_URI=$(terraform -chdir=infra/aws/25-ecr output -raw repository_url)
ACCT="$(echo "$REPO_URI" | cut -d'.' -f1)"

aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCT.dkr.ecr.$REGION.amazonaws.com

# Build/push amd64 (el node group de EKS usa x86_64)
docker-buildx build --platform linux/amd64 -t $REPO_URI:0.1.0 --push app/
```

### 6.3 Helm install

Editar `charts/hello-api/values-eks.yaml` y reemplazar `<ACCT>` por tu Account ID en `image.repository`.

```bash
helm upgrade --install hello-api charts/hello-api \
  -f charts/hello-api/values-eks.yaml \
  --namespace hello --create-namespace \
  --wait
```

### 6.4 Validación

```bash
kubectl get pods -n hello
# hello-api-xxxx Running 1/1

kubectl port-forward -n hello svc/hello-api 8080:80 &
curl http://localhost:8080/healthz
# {"ok":true}
```

Si la app necesita verificar Pod Identity en runtime:

```bash
kubectl exec -n hello deploy/hello-api -- env | grep AWS_CONTAINER_CREDENTIALS_FULL_URI
# Si aparece, Pod Identity está inyectando credenciales correctamente.
```

### Exposición pública

Continuá con **Fase 7** para instalar AWS Load Balancer Controller y exponer por ALB (default del lab).

### Commit

```
feat(eks): deploy hello-api with pod identity and helm
```

---

## 9. Fase 7 — Exposición pública con ALB (default)

**Objetivo:** que `curl http://<alb-dns>/healthz` funcione desde Internet usando Ingress + AWS Load Balancer Controller (camino L7 más común en producción).

### 7.1 Decisión: ALB como baseline

| Opción | Cómo se crea | Capa | Costo aprox. | Complejidad |
|---|---|---|---|---|
| CLB | `Service.type=LoadBalancer` | L4 | ~$18/mes 24×7 | Baja |
| **ALB (default)** | `Ingress` + controller | L7 | ~$22/mes 24×7 (con Free Tier inicial puede quedar ~$0) | Media |

Para este roadmap dejamos **ALB por default** porque es el patrón de producción más común para apps HTTP en EKS (routing por host/path, TLS con ACM, integración natural con Ingress).

### 7.2 Instalar AWS Load Balancer Controller (IaC con Terraform)

**`infra/aws/35-alb-controller/main.tf`**:
```hcl
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

module "alb_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name = "aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn = aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName = local.effective_cluster_name
    region      = "us-east-1"
    vpcId       = data.terraform_remote_state.network.outputs.vpc_id
    replicaCount = 1
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.alb_controller_irsa_role.iam_role_arn
      }
    }
  })]
}
```

```bash
cd infra/aws/35-alb-controller
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=../backend.hcl
terraform apply
cd ../../..
```

Verificar:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

> Este stack crea OIDC provider, IAM role/policy (IRSA) y Helm release del controller. No requiere `eksctl`.

### 7.3 Ingress ALB para `hello-api`

En `charts/hello-api/values-eks.yaml`:

```yaml
service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: true
  className: "alb"
  host: ""
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
```

Aplicar:

```bash
helm upgrade --install hello-api charts/hello-api \
  -f charts/hello-api/values-eks.yaml \
  --namespace hello --create-namespace --wait

kubectl get ingress -n hello -w
```

Cuando salga el DNS:

```bash
ALB=$(kubectl get ingress -n hello hello-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "URL pública: http://$ALB"
curl http://$ALB/healthz
```

### 7.4 Cleanup antes de destroy

Antes de destruir `20-eks` o `10-network`, borrar primero Ingress/Service para que el controller libere ALB, ENIs y SGs:

```bash
helm uninstall hello-api -n hello 2>/dev/null
kubectl delete ingress -A --all --ignore-not-found
kubectl delete svc -A --field-selector spec.type=LoadBalancer --ignore-not-found

sleep 60
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName'
```

### Validación

- `curl http://$ALB/healthz` devuelve `{"ok":true}`.
- `kubectl get ingress -n hello hello-api` muestra `ADDRESS` con hostname de ALB.

### Commit

```
feat(eks): expose hello-api through alb ingress
```

---

## 10. Apéndices

### A. Comandos diarios

```bash
# Levantar todo desde cero después de reboot
colima start
minikube start
helm upgrade --install hello-api charts/hello-api \
  -f charts/hello-api/values-minikube.yaml -n hello

# Pausar (sin perder estado)
minikube stop
colima stop

# Limpiar todo en local
helm uninstall hello-api -n hello
minikube delete
```

### B. Destroy AWS (NO te olvides)

> **Orden obligatorio**: Kubernetes primero (para que el cluster libere los LBs en AWS), Terraform después en orden inverso al apply. Si te salteás el paso de Kubernetes, revisá el bloque de recuperación de LBs/ENIs dentro de esta misma sección.

#### Opción 1 (recomendada): script automatizado

```bash
# Hace los pasos 1-3 de abajo + recovery automático de LBs/SGs huérfanos
AWS_PROFILE=personal ./scripts/teardown.sh

# Opciones útiles:
./scripts/teardown.sh --dry-run         # ver qué haría sin tocar nada
./scripts/teardown.sh --skip-ecr-empty  # si ya sabes que hello-api no tiene imágenes
./scripts/teardown.sh --only-recovery   # SOLO limpia LBs/SGs huérfanos (no corre terraform)
./scripts/teardown.sh --skip-k8s        # si ya perdiste acceso al cluster
```

#### Opción 2: pasos manuales

```bash
# 1) PRIMERO: limpiar recursos de K8s que crean infra en AWS (LBs, Ingresses, PVCs EBS)
helm uninstall hello-api -n hello 2>/dev/null
kubectl delete svc -A --field-selector spec.type=LoadBalancer --ignore-not-found
kubectl delete ingress -A --all --ignore-not-found
kubectl delete ns hello 2>/dev/null

# 2) Esperar a que AWS termine de borrar los LBs (~60-120s)
sleep 60
aws elb   describe-load-balancers --region us-east-1 --query 'LoadBalancerDescriptions[].LoadBalancerName'
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName'
# Ambos deben devolver [] (o solo LBs ajenos al lab) antes de seguir.

# 3) Vaciar ECR (si tiene imágenes, terraform destroy de 25-ecr puede fallar)
REPO=hello-api
if aws ecr describe-repositories --repository-names "$REPO" --region us-east-1 >/dev/null 2>&1; then
  while true; do
    IDS=$(aws ecr list-images --repository-name "$REPO" --region us-east-1 --query 'imageIds[*]' --output json)
    N=$(echo "$IDS" | jq 'length')
    [ "$N" -eq 0 ] && break
    echo "$IDS" | jq -c 'def chunks(n): [range(0; length; n) as $i | .[$i:$i+n]]; chunks(100)[]' | \
      while read -r BATCH; do
        aws ecr batch-delete-image --repository-name "$REPO" --region us-east-1 --image-ids "$BATCH" >/dev/null
      done
  done
fi

# 4) Terraform destroy en orden inverso al apply
cd infra/aws/35-alb-controller && terraform destroy -auto-approve && cd -
cd infra/aws/30-app-iam        && terraform destroy -auto-approve && cd -
cd infra/aws/25-ecr            && terraform destroy -auto-approve && cd -
cd infra/aws/20-eks            && terraform destroy -auto-approve && cd -    # ~10 min
cd infra/aws/10-network        && terraform destroy -auto-approve && cd -
# Bootstrap (00-) déjalo, cuesta centavos.
```

> Si completaste **Fase 7** (ALB activo), saltearse el paso 1 garantiza que el destroy del `10-network` falle con `DependencyViolation` en las subnets/IGW.

### C. Troubleshooting frecuente

| Síntoma | Causa probable | Fix |
|---|---|---|
| `ImagePullBackOff` en minikube | Imagen no está en el daemon del nodo | `minikube image load hello-api:0.1.0` o `eval $(minikube docker-env)` antes del build |
| `exec format error` en pod | Imagen arm64 corriendo en nodo x86_64 (`t3.micro`) | Build/push con `docker-buildx build --platform linux/amd64 ...` |
| `cgroup v1 not supported` | K8s 1.35 + runtime viejo | Usar `--container-runtime=containerd` y AMI Bottlerocket |
| `Too many pods` (FailedScheduling) en EKS | `t3.micro` tiene presupuesto de pods/IPs justo; con `desired_size=1` suele romper rápido | Asegurar `desired_size=3`, mantener addons mínimos, o subir a `t3.small` |
| `kubectl get nodes` 401 Unauthorized | Tu IAM principal no tiene access entry en EKS | Verificar `access_entries` en `20-eks/main.tf`; el caller de Terraform queda como admin automáticamente |
| `helm install` cuelga | Helm v4 cambió default | Usá Helm v3 o agregá `--wait` explícito en v4 |
| `terraform apply` falla en EKS | Versión 1.35.2/3 con minikube viejo | Usar `kubernetes_version = "1.35"` (string corto) |

### D. Checklist por fase

- [ ] Fase 0: tooling instalado
- [ ] Fase 1: `pytest` + `docker run` ok
- [ ] Fase 2: `helm test` pasa en minikube
- [ ] Fase 3: HPA reacciona a carga; CI lint en PRs
- [ ] Fase 4: bucket S3 de tfstate existe
- [ ] Fase 5: `kubectl get nodes` muestra 3 `Ready` y `terraform -chdir=infra/aws/25-ecr output -raw repository_url` devuelve URL
- [ ] Fase 6: `curl http://localhost:8080/healthz` desde port-forward devuelve `{"ok":true}`
- [ ] Fase 7: `curl http://<ALB-hostname>/healthz` desde Internet devuelve `{"ok":true}`

### E. Referencias

- Kubernetes 1.35: https://kubernetes.io/releases/1.35/
- EKS 1.35: https://aws.amazon.com/about-aws/whats-new/2026/01/amazon-eks-distro-kubernetes-version-1-35/
- terraform-aws-eks: https://github.com/terraform-aws-modules/terraform-aws-eks
- terraform-aws-vpc: https://github.com/terraform-aws-modules/terraform-aws-vpc
- EKS Pod Identity: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- VPC CNI Prefix Delegation: https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html
- FastAPI: https://fastapi.tiangolo.com

### F. Costos aproximados (us-east-1)

| Recurso | USD/mes |
|---|---|
| EKS control plane | ~73 |
| 1× t3.micro nodo x86_64 (Free Tier, 1 nodo) | $0 (cabe en 750 hrs Free Tier) |
| NAT Gateway (single) | ~32 |
| ↳ alternativa: fck-nat instance (`t3.nano`) | ~5 |
| Gateway endpoint S3 | $0 (gratis) |
| ECR (~1 GB) | <1 |
| ALB (default de exposición HTTP) | ~18-22 |
| **Free Tier 24/7 (1× t3.micro + NAT, sin LB)** | **~105** |
| **Free Tier 24/7 (1× t3.micro + fck-nat, sin LB)** | **~78** |
| **Free Tier sesiones cortas (apply → estudio → destroy)** | **~5-10** |

Hacé `terraform destroy` cuando termines del día. Levantar de nuevo: ~20 min.

> **Nota Free Tier**: el control plane de EKS NO es Free Tier (~$0.10/hora = $73/mes 24x7). El nodo `t3.micro` sí entra en Free Tier (750 hrs/mes gratis los primeros 12 meses). El NAT Gateway tampoco. En sesiones cortas (`apply` → estudiar → `destroy`) el costo real es ~$5-10/mes.

---

**Última nota:** este roadmap está diseñado para que cada fase sea un PR cerrado. No te saltes fases ni las mezcles. Cuando dudes, haz `terraform destroy` y vuelve a empezar — es **exactamente** el comportamiento que quieres practicar.