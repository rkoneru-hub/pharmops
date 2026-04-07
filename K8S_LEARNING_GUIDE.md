# Kubernetes Learning Guide — Hands-On Experiments

> **Purpose:** Practical experiments to run on your live PharmOps cluster.
> Each experiment teaches a real concept and prepares you for a DevOps/SRE interview.
>
> **Before starting:** Ensure all 5 pods are running and the app is accessible via your ALB.
> ```bash
> kubectl get pods -n dev
> ALB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
>   -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
> ```

---

## Table of Contents

1. [Explore the Running Cluster](#1-explore-the-running-cluster)
2. [Liveness and Readiness Probes — Break and Fix Them](#2-liveness-and-readiness-probes--break-and-fix-them)
3. [Scaling — Manual and Automatic](#3-scaling--manual-and-automatic)
4. [Rolling Updates and Rollbacks](#4-rolling-updates-and-rollbacks)
5. [ConfigMaps — Change Config Without Rebuilding](#5-configmaps--change-config-without-rebuilding)
6. [Secrets — How They Flow From AWS to the App](#6-secrets--how-they-flow-from-aws-to-the-app)
7. [Resource Limits — Trigger an OOMKill](#7-resource-limits--trigger-an-oomkill)
8. [Kill a Pod — Watch Self-Healing](#8-kill-a-pod--watch-self-healing)
9. [Ingress — Change Routing Rules](#9-ingress--change-routing-rules)
10. [Exec Into a Pod — Live Debugging](#10-exec-into-a-pod--live-debugging)
11. [Node Pressure — Understand Scheduling](#11-node-pressure--understand-scheduling)
12. [GitOps with ArgoCD — The Full Loop](#12-gitops-with-argocd--the-full-loop)
13. [Observe Application Logs](#13-observe-application-logs)
14. [RBAC — Control Who Can Do What](#14-rbac--control-who-can-do-what)
15. [ArgoCD Deep Dive — UI and CLI](#15-argocd-deep-dive--ui-and-cli)
16. [Helm Charts — Understand and Extend](#16-helm-charts--understand-and-extend)
17. [Migrate pharma-ui From Raw Manifests to Helm](#17-migrate-pharma-ui-from-raw-manifests-to-helm)

---

## 1. Explore the Running Cluster

**Concept:** Understand what's running and how everything connects.

```bash
# All resources in dev namespace
kubectl get all -n dev

# Describe a pod — see image, ports, env vars, volumes, events
kubectl describe pod -n dev $(kubectl get pod -n dev -l app.kubernetes.io/name=auth-service -o jsonpath='{.items[0].metadata.name}')

# See what environment variables a pod has (including secrets injected as env vars)
kubectl exec -n dev deployment/auth-service -- env | sort

# See the configmap values for api-gateway
kubectl get configmap api-gateway -n dev -o yaml

# Check what secrets exist in dev namespace
kubectl get secrets -n dev

# See the actual ingress routing rules
kubectl describe ingress -n dev
```

**What to look for:**
- Notice `DB_USERNAME`, `DB_PASSWORD`, `JWT_SECRET` in env — these come from K8s Secrets, not the YAML files
- Notice `DB_HOST`, `LOG_LEVEL`, `SERVER_PORT` — these come from the ConfigMap
- Notice the ingress routes `/` to pharma-ui and `/api` to api-gateway

**Interview Question:** *"How do you find out what environment variables a running pod has?"*
> `kubectl exec <pod> -- env` — or `kubectl describe pod` to see the sources (secretRef, configMapRef).

---

## 2. Liveness and Readiness Probes — Break and Fix Them

**Concept:** Kubernetes uses probes to know if a pod is alive and ready to serve traffic.

### Experiment 2a — Observe Current Probes

```bash
# See the probe configuration on auth-service
kubectl get deployment auth-service -n dev -o yaml | grep -A 15 "livenessProbe"
kubectl get deployment auth-service -n dev -o yaml | grep -A 15 "readinessProbe"
```

Notice:
- `livenessProbe` — if this fails 3 times, Kubernetes **restarts** the pod
- `readinessProbe` — if this fails, Kubernetes **stops sending traffic** to the pod (but doesn't restart it)
- `initialDelaySeconds: 60` — Spring Boot takes ~60s to start, so Kubernetes waits before checking

### Experiment 2b — Hit the Health Endpoints Directly

```bash
# Liveness endpoint (is the app running?)
kubectl exec -n dev deployment/api-gateway -- \
  curl -s http://auth-service:8081/actuator/health/liveness

# Readiness endpoint (is the app ready for traffic?)
kubectl exec -n dev deployment/api-gateway -- \
  curl -s http://auth-service:8081/actuator/health/readiness

# Full health details including DB connection
kubectl exec -n dev deployment/api-gateway -- \
  curl -s http://auth-service:8081/actuator/health | python3 -m json.tool
```

### Experiment 2c — Watch a Pod Restart Due to Failed Probe

```bash
# Watch pod restarts in real time (open in a separate terminal)
kubectl get pods -n dev -w

# In another terminal — set an impossible liveness probe path to force restarts
kubectl patch deployment auth-service -n dev --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/this-path-does-not-exist"}]'

# Watch the RESTARTS column increase — Kubernetes kills and restarts the pod
# After ~3 failures (45 seconds), you'll see restart count go up
kubectl get pods -n dev -w
```

**Restore it:**
```bash
kubectl patch deployment auth-service -n dev --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/actuator/health"}]'
```

**Interview Question:** *"What is the difference between liveness and readiness probes?"*
> Liveness: is the app alive? If it fails, restart the pod.
> Readiness: is the app ready for traffic? If it fails, remove from Service endpoints but don't restart.
> Use readiness to handle slow startups or temporary overloads without killing the pod.

---

## 3. Scaling — Manual and Automatic

**Concept:** Kubernetes can scale pods manually or automatically based on CPU usage.

### Experiment 3a — Manual Scale Up

```bash
# Current state
kubectl get pods -n dev | grep notification

# Scale notification-service to 3 replicas
kubectl scale deployment notification-service -n dev --replicas=3

# Watch pods come up
kubectl get pods -n dev -w

# Scale back down
kubectl scale deployment notification-service -n dev --replicas=1
```

### Experiment 3b — Inspect HPA Configuration

The values files define HPA (Horizontal Pod Autoscaler) config — check it:

```bash
# List HPAs (autoscaling not enabled by default in dev, but you can create one)
kubectl get hpa -n dev

# Create an HPA for notification-service manually
kubectl autoscale deployment notification-service -n dev \
  --min=1 --max=3 --cpu-percent=50

kubectl get hpa -n dev -w
# Watch TARGETS — it shows current CPU% vs target
```

### Experiment 3c — See How Many Pods a Node Can Hold

```bash
# Check node capacity
kubectl describe nodes | grep -A 5 "Allocatable:"

# Check how many pods are already on each node
kubectl get pods -A -o wide | awk '{print $8}' | sort | uniq -c
```

**Interview Question:** *"How does HPA decide when to scale?"*
> It checks the metrics-server every 15 seconds. If average CPU across all pods exceeds the target percentage, it adds pods (up to maxReplicas). When load drops, it scales down after a cooldown period (default 5 minutes).

---

## 4. Rolling Updates and Rollbacks

**Concept:** Zero-downtime deployments — Kubernetes replaces pods one by one.

### Experiment 4a — Trigger a Rolling Update

```bash
# Watch pods during the update (run in a separate terminal)
kubectl get pods -n dev -w

# Trigger a rolling update by changing an env var (forces pod recreation)
kubectl set env deployment/notification-service -n dev LOG_LEVEL=INFO

# In the watch terminal you'll see:
# - New pod starts (Pending → Running)
# - Old pod terminates
# All without downtime
```

### Experiment 4b — Check Rollout History

```bash
# See rollout history
kubectl rollout history deployment/notification-service -n dev

# See details of a specific revision
kubectl rollout history deployment/notification-service -n dev --revision=2
```

### Experiment 4c — Rollback

```bash
# Rollback to the previous version
kubectl rollout undo deployment/notification-service -n dev

# Verify
kubectl rollout status deployment/notification-service -n dev
kubectl get pods -n dev | grep notification
```

### Experiment 4d — Understand maxSurge and maxUnavailable

```bash
# Check the rolling update strategy
kubectl get deployment notification-service -n dev -o yaml \
  | grep -A 5 "strategy"
```

**Interview Question:** *"How does Kubernetes achieve zero-downtime deployments?"*
> Rolling update strategy. `maxSurge: 1` means it can create 1 extra pod above desired count. `maxUnavailable: 0` means no pod is removed until the new one is Ready. So at no point is capacity reduced below 100%.

---

## 5. ConfigMaps — Change Config Without Rebuilding

**Concept:** ConfigMaps let you change application config without rebuilding the Docker image.

### Experiment 5a — Change Log Level Live

```bash
# Check current log level
kubectl get configmap auth-service -n dev -o yaml | grep LOG_LEVEL

# Change log level to TRACE
kubectl set env deployment/auth-service -n dev LOG_LEVEL=TRACE

# Wait for pod to restart, then watch verbose logs
kubectl logs -n dev deployment/auth-service -f
# You'll see significantly more log output at TRACE level

# Set it back
kubectl set env deployment/auth-service -n dev LOG_LEVEL=DEBUG
```

### Experiment 5b — Inspect the Full ConfigMap

```bash
# See all config values for each service
for svc in api-gateway auth-service drug-catalog-service notification-service pharma-ui; do
  echo "=== $svc ==="
  kubectl get configmap $svc -n dev -o yaml 2>/dev/null | grep -A 50 "^data:"
  echo ""
done
```

**Interview Question:** *"What is the difference between a ConfigMap and a Secret?"*
> Both inject config into pods as env vars or files. ConfigMaps are for non-sensitive config (log level, port, URLs). Secrets are for sensitive data (passwords, tokens) — stored base64-encoded in etcd, and in our project, synced from AWS Secrets Manager by External Secrets Operator so they never touch Git.

---

## 6. Secrets — How They Flow From AWS to the App

**Concept:** Trace the full journey of a secret from AWS Secrets Manager to the app.

### Experiment 6a — Check What's in AWS Secrets Manager

```bash
# See the secret paths Terraform created
aws secretsmanager list-secrets --query 'SecretList[].Name' --output table

# See the actual value (do this once for understanding — never do this in prod)
aws secretsmanager get-secret-value \
  --secret-id /pharma/dev/db-credentials \
  --query SecretString --output text
```

### Experiment 6b — Check the ExternalSecret Status

```bash
# Check if ESO successfully synced the secrets
kubectl get externalsecret -n dev
# STATUS should be: SecretSynced

# See details — last sync time, any errors
kubectl describe externalsecret db-credentials -n dev
```

### Experiment 6c — Inspect the K8s Secret

```bash
# List secrets in dev
kubectl get secrets -n dev

# See the secret (values are base64 encoded)
kubectl get secret db-credentials -n dev -o yaml

# Decode the values
kubectl get secret db-credentials -n dev \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d
echo ""
kubectl get secret db-credentials -n dev \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
echo ""
```

### Experiment 6d — Verify the Pod Receives the Secret

```bash
# The pod should have DB_USERNAME and DB_PASSWORD as env vars
kubectl exec -n dev deployment/auth-service -- env | grep DB_
```

**Interview Question:** *"How do you avoid storing secrets in Git?"*
> We use External Secrets Operator with AWS Secrets Manager. Terraform creates the secrets in AWS SM. ESO (running in the cluster) reads them using an IAM role via IRSA and creates Kubernetes Secrets automatically. The GitOps repo only contains the ExternalSecret resource (which references the AWS secret path) — never the actual value.

---

## 7. Resource Limits — Trigger an OOMKill

**Concept:** What happens when a pod uses more memory than its limit.

### Experiment 7a — Check Current Resource Requests and Limits

```bash
kubectl get deployment auth-service -n dev -o yaml \
  | grep -A 10 "resources:"
```

### Experiment 7b — Set a Very Low Memory Limit

```bash
# Set an extremely low memory limit to trigger OOMKill
kubectl patch deployment notification-service -n dev --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"10Mi"}]'

# Watch what happens
kubectl get pods -n dev -w
# Pod will be OOMKilled and show: OOMKilled in STATUS
kubectl describe pod -n dev $(kubectl get pod -n dev -l app.kubernetes.io/name=notification-service -o jsonpath='{.items[0].metadata.name}') \
  | grep -A 5 "Last State:"
```

**Restore:**
```bash
kubectl patch deployment notification-service -n dev --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"256Mi"}]'
```

**Interview Question:** *"What is the difference between resource requests and limits?"*
> Requests: what the pod is guaranteed — used by the scheduler to find a node with enough capacity.
> Limits: the maximum a pod can use — if it exceeds memory limit, the kernel OOMKills it. If it exceeds CPU limit, it is throttled (slowed down, not killed).

---

## 8. Kill a Pod — Watch Self-Healing

**Concept:** Kubernetes automatically restarts failed pods to maintain desired state.

```bash
# Open a watch in one terminal
kubectl get pods -n dev -w

# In another terminal — delete a pod (simulate a crash)
kubectl delete pod -n dev $(kubectl get pod -n dev -l app.kubernetes.io/name=auth-service -o jsonpath='{.items[0].metadata.name}')

# In the watch terminal you'll immediately see:
# - auth-service pod → Terminating
# - New auth-service pod → Pending → ContainerCreating → Running
# The Deployment controller noticed 0/1 replicas and created a new pod
```

```bash
# Check how many times a pod has been restarted
kubectl get pods -n dev
# RESTARTS column shows total restarts since pod was created
```

**Interview Question:** *"What restarts a pod when it crashes?"*
> The Deployment controller (part of kube-controller-manager) continuously watches the actual vs desired state. When a pod dies, the actual count drops below desired — the controller immediately creates a replacement. This is the reconciliation loop.

---

## 9. Ingress — Change Routing Rules

**Concept:** The Ingress Controller routes traffic based on host and path rules.

### Experiment 9a — Inspect nginx Configuration Generated by Ingress

```bash
# See the actual nginx config that was generated from your Ingress YAMLs
NGINX_POD=$(kubectl get pod -n ingress-nginx \
  -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n ingress-nginx $NGINX_POD -- \
  cat /etc/nginx/nginx.conf | grep -A 3 "location /api"
```

### Experiment 9b — Test Routing From Inside the Cluster

```bash
# Test that /api routes to api-gateway and / routes to pharma-ui
# (from inside a pod, using the service names directly)
kubectl exec -n dev deployment/api-gateway -- \
  curl -s http://pharma-ui:80 | head -5
# Expected: HTML of the React app

kubectl exec -n dev deployment/pharma-ui -- \
  curl -s http://api-gateway:8080/actuator/health
# Expected: {"status":"UP"...}
```

### Experiment 9c — See What Happens Without the Host Match

```bash
ALB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Request with wrong Host header — nginx returns 404
curl -s -H "Host: wrong.host.com" http://${ALB}/
# Expected: 404

# Request with correct Host header — works
curl -s -H "Host: ${ALB}" http://${ALB}/ | head -3
# Expected: HTML
```

**Interview Question:** *"How does nginx ingress route traffic to different services?"*
> nginx ingress controller watches for Ingress resources and generates nginx configuration automatically. When a request arrives, nginx checks the Host header and path against the rules. In our project, path `/api` goes to api-gateway and `/` goes to pharma-ui — both share a single ELB entry point.

---

## 10. Exec Into a Pod — Live Debugging

**Concept:** You can get a shell inside any running pod to debug issues.

```bash
# Get a shell inside the api-gateway pod
kubectl exec -it -n dev deployment/api-gateway -- /bin/sh

# Inside the pod — try these:
env | grep -E "AUTH|DRUG|NOTIFICATION"   # see service URLs
curl -s http://auth-service:8081/actuator/health  # test connectivity
curl -s http://drug-catalog-service:8082/actuator/health
curl -s http://notification-service:3000/actuator/health
cat /app/app.jar | wc -c               # check the jar size
exit
```

```bash
# Check DNS resolution inside the cluster
kubectl exec -n dev deployment/api-gateway -- \
  nslookup auth-service.dev.svc.cluster.local
# Kubernetes DNS resolves service names to ClusterIP
```

**Interview Question:** *"How do microservices discover and communicate with each other in Kubernetes?"*
> Via Kubernetes DNS. Every Service gets a DNS name: `<service>.<namespace>.svc.cluster.local`. In our project, the api-gateway is configured with `AUTH_SERVICE_URL=http://auth-service:8081` — Kubernetes DNS resolves `auth-service` to the ClusterIP of the auth-service Service, which load-balances across all auth-service pods.

---

## 11. Node Pressure — Understand Scheduling

**Concept:** The Kubernetes scheduler places pods on nodes based on available resources.

```bash
# See all nodes and their status
kubectl get nodes -o wide

# See resource usage per node
kubectl top nodes

# See resource usage per pod
kubectl top pods -n dev

# See how pods are distributed across nodes
kubectl get pods -n dev -o wide
# NODE column shows which node each pod runs on

# See node capacity and allocated resources
kubectl describe node <node-name> | grep -A 20 "Allocated resources:"
```

```bash
# See why a pod was scheduled on a specific node
kubectl describe pod -n dev \
  $(kubectl get pod -n dev -l app.kubernetes.io/name=auth-service \
  -o jsonpath='{.items[0].metadata.name}') | grep -A 5 "Events:"
```

**Interview Question:** *"How does the Kubernetes scheduler decide where to place a pod?"*
> It filters nodes that meet the pod's requirements (enough CPU/memory requests, matching nodeSelector/affinity rules, no taints). Then it scores the remaining nodes — preferring nodes with more available resources, spreading replicas across nodes (if anti-affinity is set). In our prod values, we use `podAntiAffinity` to ensure two replicas of the same service never land on the same node.

---

## 12. GitOps with ArgoCD — The Full Loop

**Concept:** Every change flows through Git — ArgoCD detects and applies it automatically.

### Experiment 12a — Make a Config Change and Watch It Deploy

```bash
# 1. Edit a value in your pharmops-gitops repo
# Change LOG_LEVEL from DEBUG to INFO in envs/dev/values-notification-service.yaml

# 2. Commit and push
git add envs/dev/values-notification-service.yaml
git commit -m "chore: change notification-service log level to INFO"
git push

# 3. Watch ArgoCD detect and sync (within ~3 minutes)
kubectl port-forward svc/argocd-server -n argocd 8090:443 &
argocd app get notification-service-dev --server localhost:8090 --insecure

# 4. Verify the change applied
kubectl get configmap notification-service -n dev -o yaml | grep LOG_LEVEL
# Expected: INFO
```

### Experiment 12b — Manually Edit a Resource and Watch ArgoCD Revert It

```bash
# Manually change a configmap (simulating someone bypassing GitOps)
kubectl patch configmap notification-service -n dev \
  --type merge -p '{"data":{"LOG_LEVEL":"TRACE"}}'

# Verify the manual change
kubectl get configmap notification-service -n dev -o yaml | grep LOG_LEVEL
# Shows: TRACE

# Wait ~3 minutes OR force a sync
argocd app sync notification-service-dev --server localhost:8090 --insecure

# ArgoCD reverts it back to what's in Git
kubectl get configmap notification-service -n dev -o yaml | grep LOG_LEVEL
# Back to: INFO (or whatever is in Git)
```

**Interview Question:** *"What is GitOps and why is it better than running kubectl apply manually?"*
> GitOps uses Git as the single source of truth for infrastructure state. ArgoCD continuously reconciles the cluster state with what's in Git. Benefits: full audit trail (Git history), easy rollback (git revert), no manual kubectl in production, drift detection (if someone changes something manually, ArgoCD detects and reverts it).

---

## 13. Observe Application Logs

**Concept:** Logs are your first debugging tool. Learn to read them efficiently.

```bash
# Follow logs in real time
kubectl logs -n dev deployment/auth-service -f

# In another terminal — make a login request
ALB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -X POST http://${ALB}/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme"}'

# Watch the log line appear in real time in auth-service logs
```

```bash
# See logs from a crashed pod (previous container)
kubectl logs -n dev deployment/auth-service --previous 2>/dev/null \
  || echo "No previous container — pod hasn't crashed"

# Filter logs for errors only
kubectl logs -n dev deployment/auth-service --tail=200 | grep -i "error\|exception\|warn"

# See logs from all pods of a deployment simultaneously
kubectl logs -n dev deployment/api-gateway --all-containers=true
```

```bash
# See Kubernetes events (cluster-level logs)
kubectl get events -n dev --sort-by='.lastTimestamp' | tail -20
```

**Interview Question:** *"How do you debug a microservice that is returning 500 errors?"*
> First `kubectl get pods -n dev` to check pod health and restart count. Then `kubectl logs <pod>` to read the application logs — look for exceptions. `kubectl describe pod <pod>` to check events (OOMKill, probe failures, image pull errors). If the pod is running, `kubectl exec -it <pod> -- /bin/sh` to inspect the environment and test connectivity to dependencies.

---

## 14. RBAC — Control Who Can Do What

**Concept:** Role-Based Access Control limits what each user/service can do in the cluster.

```bash
# See the roles defined in the project
kubectl get roles -n dev
kubectl get clusterroles | grep pharma

# Describe a role to see what permissions it grants
kubectl describe role -n dev pharma-developer 2>/dev/null \
  || kubectl get role -n dev -o yaml 2>/dev/null | head -40

# See role bindings (who has which role)
kubectl get rolebindings -n dev
kubectl describe rolebinding -n dev
```

```bash
# Test what a service account can do (impersonation)
kubectl auth can-i get pods -n dev \
  --as=system:serviceaccount:dev:api-gateway
# Expected: yes

kubectl auth can-i delete deployments -n dev \
  --as=system:serviceaccount:dev:api-gateway
# Expected: no (service accounts shouldn't be able to delete deployments)
```

```bash
# See the service accounts in dev namespace
kubectl get serviceaccounts -n dev

# See the annotations on api-gateway service account (IAM role binding)
kubectl describe serviceaccount api-gateway -n dev
# Look for: eks.amazonaws.com/role-arn annotation — this is IRSA
```

**Interview Question:** *"What is RBAC in Kubernetes and why does it matter?"*
> RBAC controls what actions each identity (user, service account) can perform on which resources. A Role defines permissions within a namespace; a ClusterRole applies cluster-wide. In our project, each microservice has its own ServiceAccount — the api-gateway's ServiceAccount has an IAM role annotation (IRSA) that allows it to access AWS services. This follows least-privilege: each pod only has the AWS permissions it actually needs.

---

## 15. ArgoCD Deep Dive — UI and CLI

**Concept:** ArgoCD is the GitOps engine that keeps your cluster in sync with Git. Learn to navigate it confidently.

### Experiment 15a — Explore the ArgoCD UI

```bash
# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8090:443 &
# Open: https://localhost:8090
# Username: admin
# Password:
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

**In the UI, explore:**
1. **Applications list** — see all 5 apps with their Sync and Health status
2. **Click an app (e.g. api-gateway-dev)** — see the resource tree: Deployment → ReplicaSet → Pods
3. **Click a Pod** in the tree — see its logs directly from ArgoCD UI
4. **Click the Deployment** — see the manifest ArgoCD generated from Helm values
5. **App Details → Summary tab** — see the repo URL, path, target revision, last sync time
6. **App Details → Parameters tab** — see all Helm values currently applied
7. **App Details → Events tab** — see sync history

### Experiment 15b — Understand Sync Status via CLI

```bash
ARGOCD="--server localhost:8090 --insecure"

# List all apps with sync and health status
argocd app list $ARGOCD

# Get detailed status of one app
argocd app get api-gateway-dev $ARGOCD

# See what ArgoCD WOULD change (diff between Git and cluster)
argocd app diff api-gateway-dev $ARGOCD
# If empty — cluster matches Git exactly (Synced)
# If not empty — shows what would change on next sync
```

### Experiment 15c — Simulate Drift and Watch ArgoCD Detect It

```bash
# Manually change a replica count (bypass GitOps — simulate human error)
kubectl scale deployment notification-service -n dev --replicas=2

# Check ArgoCD immediately sees the drift
argocd app get notification-service-dev $ARGOCD
# Sync Status: OutOfSync
# The diff shows: replicas 1 (Git) vs 2 (cluster)

# ArgoCD self-heal kicks in automatically (selfHeal: true in syncPolicy)
# Wait ~30 seconds and check again
kubectl get deployment notification-service -n dev -o jsonpath='{.spec.replicas}'
# Expected: 1 (ArgoCD reverted it back)
```

### Experiment 15d — Manual Sync and Hard Refresh

```bash
ARGOCD="--server localhost:8090 --insecure"

# Force an immediate sync (don't wait for auto-detect)
argocd app sync api-gateway-dev $ARGOCD

# Hard refresh — clears ArgoCD's manifest cache and re-fetches from Git
# Use this when ArgoCD shows stale state after a push
argocd app get api-gateway-dev --hard-refresh $ARGOCD

# Sync with pruning — deletes resources that are in cluster but not in Git
argocd app sync api-gateway-dev --prune $ARGOCD
```

### Experiment 15e — Rollback via ArgoCD

```bash
ARGOCD="--server localhost:8090 --insecure"

# See sync history (each entry is a Git commit that was synced)
argocd app history api-gateway-dev $ARGOCD

# Rollback to a previous Git revision (by history ID)
argocd app rollback api-gateway-dev <ID> $ARGOCD

# In the UI: App → History and Rollback → click any past deployment → Rollback
```

### Experiment 15f — Explore the ArgoCD Project

```bash
# See the pharma project — what repos and namespaces are allowed
kubectl get appproject pharma -n argocd -o yaml

# Key fields:
# sourceRepos: which Git repos ArgoCD can pull from
# destinations: which clusters/namespaces apps can deploy to
# clusterResourceWhitelist: what cluster-level resources are allowed
```

**Interview Question:** *"What is ArgoCD and how does it implement GitOps?"*
> ArgoCD is a declarative GitOps tool for Kubernetes. It continuously polls Git repositories and compares the desired state (YAML/Helm in Git) with the actual state in the cluster. When drift is detected, it either alerts (manual sync) or automatically reconciles (automated sync with selfHeal). Every deployment is a Git commit — full audit trail, easy rollback, no manual kubectl in production.

**Interview Question:** *"What is the difference between ArgoCD Sync and Health status?"*
> Sync status: does the cluster match what's in Git? (Synced / OutOfSync)
> Health status: is the application actually running correctly? (Healthy / Degraded / Progressing)
> A deployment can be Synced but Degraded — e.g., ArgoCD applied the manifest but pods are CrashLooping.

**Interview Question:** *"What is selfHeal in ArgoCD?"*
> When `selfHeal: true`, ArgoCD automatically reverts any manual changes to the cluster back to the Git state. This enforces GitOps strictly — the cluster always matches Git, even if someone runs `kubectl` directly.

---

## 16. Helm Charts — Understand and Extend

**Concept:** Helm is the package manager for Kubernetes. It templates YAML so one chart serves all environments.

### Experiment 16a — Understand the Shared Chart Structure

```bash
# Our project uses ONE shared Helm chart for all 5 backend services
ls helm-charts/
# Chart.yaml       — chart metadata (name, version)
# values.yaml      — default values (overridden per service)
# templates/       — templated YAML files

ls helm-charts/templates/
# deployment.yaml, service.yaml, configmap.yaml,
# ingress.yaml, hpa.yaml, serviceaccount.yaml, _helpers.tpl
```

```bash
# See how the chart is used differently per service
# api-gateway gets: ingress enabled, specific ports, specific URLs
cat envs/dev/values-api-gateway.yaml

# auth-service gets: different port, different probes, JWT secret
cat envs/dev/values-auth-service.yaml

# Same chart, completely different deployed resources
```

### Experiment 16b — Render Helm Templates Locally

```bash
cd pharmops-gitops

# Render what ArgoCD would actually apply for api-gateway
helm template api-gateway helm-charts \
  -f envs/dev/values-api-gateway.yaml

# Render just the deployment
helm template api-gateway helm-charts \
  -f envs/dev/values-api-gateway.yaml \
  --show-only templates/deployment.yaml

# Render for auth-service using the SAME chart
helm template auth-service helm-charts \
  -f envs/dev/values-auth-service.yaml \
  --show-only templates/deployment.yaml

# Compare the two — same template, different output
```

### Experiment 16c — Understand _helpers.tpl

```bash
cat helm-charts/templates/_helpers.tpl
```

Notice `pharma-service.fullname`:
- If `fullnameOverride` is set → use it directly (e.g. `drug-catalog-service`)
- Otherwise → combine release name + chart name

**Why this matters:** The K8s Service name must match what the api-gateway uses as the URL:
```yaml
# values-catalog-service.yaml
fullnameOverride: drug-catalog-service  # K8s service name = drug-catalog-service

# values-api-gateway.yaml
DRUG_CATALOG_URL: "http://drug-catalog-service:8082"  # must match exactly
```

### Experiment 16d — Validate a Chart Change

```bash
cd pharmops-gitops

# Add a new env var to api-gateway configmap
# Edit envs/dev/values-api-gateway.yaml — add under configmap:
#   FEATURE_FLAG: "true"

# Validate the change renders correctly before pushing
helm template api-gateway helm-charts \
  -f envs/dev/values-api-gateway.yaml \
  --show-only templates/configmap.yaml
# Expected: FEATURE_FLAG: "true" appears in the output

# Lint the chart for errors
helm lint helm-charts -f envs/dev/values-api-gateway.yaml
# Expected: 1 chart(s) linted, 0 chart(s) failed
```

### Experiment 16e — Compare Helm vs Raw Manifests

Right now pharma-ui uses raw K8s manifests (`k8s-manifests/pharma-ui/`). Compare with auth-service which uses Helm:

```bash
# pharma-ui raw manifests — 5 separate files, each hardcoded
ls k8s-manifests/pharma-ui/
# deployment.yaml, service.yaml, ingress.yaml, configmap.yaml, serviceaccount.yaml

# auth-service via Helm — 1 values file, templates are shared
ls envs/dev/ | grep auth
# values-auth-service.yaml  ← only this needs to exist

# If you had 10 environments, raw manifests = 50 files to maintain
# Helm = 10 values files, templates stay the same
```

**Interview Question:** *"What is Helm and why use it over plain YAML?"*
> Helm is a Kubernetes package manager. A Helm chart is a collection of templated YAML files — values are injected at deploy time from a `values.yaml` file. This means one chart serves all environments (dev/qa/prod) — you only change the values. In our project, one shared `helm-charts/` folder deploys all 4 backend services, each with its own values file. Without Helm you'd have 20 nearly-identical YAML files to maintain.

**Interview Question:** *"What is the difference between `helm install` and `helm upgrade --install`?"*
> `helm install` fails if the release already exists. `helm upgrade --install` creates it if missing or upgrades it if it exists — idempotent, safe to run repeatedly. Always use `helm upgrade --install` in CI/CD pipelines.

**Interview Question:** *"How does ArgoCD use Helm?"*
> ArgoCD has Helm built in. When an Application has `path: helm-charts` with `helm.valueFiles`, ArgoCD runs `helm template` locally to generate the final YAML manifests, then applies them. It doesn't use `helm install` — it uses Helm purely as a template engine, then manages the resources itself.

---

## 17. Migrate pharma-ui From Raw Manifests to Helm

**Concept:** pharma-ui currently uses 5 separate raw manifest files. Migrating it to the shared Helm chart reduces maintenance and makes it consistent with the other services.

**Why pharma-ui uses raw manifests now:** It was set up this way to demonstrate the difference between the two approaches. But in a real project, you'd use Helm for all services.

### Step 1 — Understand What the Raw Manifests Contain

```bash
ls k8s-manifests/pharma-ui/
# deployment.yaml      — image, ports, probes, resource limits, volumes
# service.yaml         — ClusterIP on port 80
# ingress.yaml         — host, path /
# configmap.yaml       — API_BASE_URL, AUTH_BASE_URL, ENV
# serviceaccount.yaml  — service account
```

Compare these with `envs/dev/values-pharma-ui.yaml` — that file already exists and already has all these values defined for Helm. The raw manifests are effectively duplicating information.

### Step 2 — Verify the Helm Values File Is Complete

```bash
cat envs/dev/values-pharma-ui.yaml
```

Check it has:
- `image.repository` and `image.tag`
- `service.port: 80`
- `ingress.enabled: true`, `ingress.host`, `ingress.path: /`
- `configmap` with `API_BASE_URL`, `AUTH_BASE_URL`, `ENV`
- `volumeMounts` and `volumes` for nginx writable directories
- `serviceAccount.name: pharma-ui`

### Step 3 — Render the Helm Templates to Verify

```bash
cd pharmops-gitops

# Render the full output — compare mentally with the raw manifests
helm template pharma-ui helm-charts \
  -f envs/dev/values-pharma-ui.yaml

# Check each resource type specifically
helm template pharma-ui helm-charts -f envs/dev/values-pharma-ui.yaml \
  --show-only templates/deployment.yaml

helm template pharma-ui helm-charts -f envs/dev/values-pharma-ui.yaml \
  --show-only templates/ingress.yaml

helm template pharma-ui helm-charts -f envs/dev/values-pharma-ui.yaml \
  --show-only templates/configmap.yaml
```

Verify the rendered output matches what's in `k8s-manifests/pharma-ui/`.

### Step 4 — Update the ArgoCD Application

Change `pharma-ui-app.yaml` from raw manifest path to Helm chart:

```yaml
# Before (raw manifests)
source:
  repoURL: https://github.com/<YOUR_GITHUB_USERNAME>/pharmops-gitops.git
  targetRevision: HEAD
  path: k8s-manifests/pharma-ui        # ← raw YAML files

# After (Helm chart)
source:
  repoURL: https://github.com/<YOUR_GITHUB_USERNAME>/pharmops-gitops.git
  targetRevision: HEAD
  path: helm-charts                     # ← shared Helm chart
  helm:
    valueFiles:
      - ../envs/dev/values-pharma-ui.yaml
```

### Step 5 — Apply and Verify

```bash
# Apply the updated ArgoCD application
kubectl apply -f argocd/apps/dev/pharma-ui-app.yaml

# Watch ArgoCD sync
argocd app get pharma-ui-dev --server localhost:8090 --insecure

# Verify the pharma-ui pod is still running after the switch
kubectl get pods -n dev | grep pharma-ui

# Verify the app still works
ALB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://${ALB}/ | head -5
# Expected: HTML of the React app
```

### Step 6 — Clean Up the Raw Manifests (Optional)

Once confirmed working via Helm, the raw manifests are no longer needed:

```bash
# The k8s-manifests/pharma-ui/ directory can be removed
# ArgoCD no longer reads it
git rm -r k8s-manifests/pharma-ui/
git commit -m "chore: remove pharma-ui raw manifests — now managed by Helm chart"
git push
```

**Interview Question:** *"When would you use raw Kubernetes manifests vs Helm?"*
> Raw manifests are simpler for one-off resources (namespaces, RBAC, CRDs) or when you need full control with no templating. Helm is better for application deployments where the same structure is reused across services or environments. In our project, using one shared Helm chart for all microservices means a probe configuration fix benefits all services at once — update the template, all services get the change on next sync.

**Interview Question:** *"What are the risks of migrating from raw manifests to Helm mid-project?"*
> The main risk is resource ownership. ArgoCD tracks resources by their source. During migration, ArgoCD may try to delete the old raw-manifest resources and recreate them via Helm, causing a brief restart. To minimise risk: use `--prune` carefully, verify Helm renders identical resources before switching, and test in a non-production namespace first.

---

## Quick Reference — Most Useful Commands

```bash
# === PODS ===
kubectl get pods -n dev                          # list pods
kubectl describe pod <pod> -n dev                # full details + events
kubectl logs -n dev deployment/<name> -f         # follow logs
kubectl exec -it -n dev deployment/<name> -- sh  # shell into pod
kubectl delete pod <pod> -n dev                  # force restart

# === DEPLOYMENTS ===
kubectl get deployments -n dev
kubectl scale deployment <name> -n dev --replicas=3
kubectl rollout history deployment/<name> -n dev
kubectl rollout undo deployment/<name> -n dev

# === CONFIG ===
kubectl get configmap <name> -n dev -o yaml
kubectl get secret <name> -n dev -o yaml
kubectl set env deployment/<name> -n dev KEY=VALUE

# === CLUSTER ===
kubectl get nodes -o wide
kubectl top nodes
kubectl top pods -n dev
kubectl get events -n dev --sort-by='.lastTimestamp'

# === ARGOCD ===
argocd app list --server localhost:8090 --insecure
argocd app get <app> --server localhost:8090 --insecure
argocd app get <app> --hard-refresh --server localhost:8090 --insecure
argocd app sync <app> --server localhost:8090 --insecure
argocd app sync <app> --prune --server localhost:8090 --insecure
argocd app diff <app> --server localhost:8090 --insecure
argocd app history <app> --server localhost:8090 --insecure
argocd app rollback <app> <id> --server localhost:8090 --insecure

# === HELM ===
helm template <release> helm-charts -f envs/dev/values-<svc>.yaml
helm template <release> helm-charts -f envs/dev/values-<svc>.yaml --show-only templates/deployment.yaml
helm lint helm-charts -f envs/dev/values-<svc>.yaml
```

---

## Interview Topics Covered by These Experiments

| Experiment | Topics |
|-----------|--------|
| 1 — Explore | Pods, Deployments, Services, ConfigMaps, Secrets |
| 2 — Probes | Liveness, Readiness, Spring Boot health |
| 3 — Scaling | HPA, manual scaling, node capacity |
| 4 — Rolling Update | Zero-downtime deployment, maxSurge, rollback |
| 5 — ConfigMaps | Config injection, hot changes |
| 6 — Secrets | External Secrets, IRSA, AWS Secrets Manager |
| 7 — Resource Limits | OOMKill, requests vs limits, throttling |
| 8 — Self-Healing | Reconciliation loop, Deployment controller |
| 9 — Ingress | nginx ingress, routing rules, host matching |
| 10 — Exec/Debug | Live debugging, cluster DNS, service discovery |
| 11 — Scheduling | Node pressure, affinity, resource allocation |
| 12 — GitOps | ArgoCD sync, drift detection, reconciliation |
| 13 — Logs | Log levels, events, debugging 500 errors |
| 14 — RBAC | Roles, service accounts, IRSA, least privilege |
| 15 — ArgoCD Deep Dive | UI navigation, sync/health, selfHeal, rollback, projects |
| 16 — Helm Charts | Templates, values, _helpers.tpl, helm template, lint |
| 17 — pharma-ui to Helm | Raw manifests vs Helm, migration, ArgoCD app update |
| 12 — GitOps | ArgoCD, drift detection, reconciliation |
| 13 — Logs | Log levels, events, debugging 500 errors |
| 14 — RBAC | Roles, service accounts, IRSA, least privilege |
