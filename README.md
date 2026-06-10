# T-DOP-603 — Bernstein

Déploiement d'une application de vote sur Kubernetes (minikube multi-nœuds).

## Architecture

```
                        ┌─────────────┐
                        │   Traefik   │  :30021 (HTTP) / :30042 (dashboard)
                        └──────┬──────┘
               ┌───────────────┘───────────────┐
               ▼                               ▼
        poll.dop.io                      result.dop.io
        ┌──────────┐                     ┌──────────┐
        │   Poll   │                     │  Result  │
        │ (Flask)  │                     │ (Node.js)│
        └────┬─────┘                     └────┬─────┘
             │ push votes                     │ read votes
             ▼                               ▼
        ┌─────────┐    consume         ┌──────────────┐
        │  Redis  │ ──────────────►    │   PostgreSQL │
        └─────────┘     Worker         └──────────────┘
```

| Composant  | Image                                  | Replicas |
|------------|----------------------------------------|----------|
| Poll       | epitechcontent/t-dop-600-poll:k8s      | 2        |
| Worker     | epitechcontent/t-dop-600-worker:k8s    | 1        |
| Result     | epitechcontent/t-dop-600-result:k8s    | 2        |
| Redis      | redis:5.0                              | 1        |
| PostgreSQL | postgres:16                            | 1        |
| Traefik    | traefik:2.7                            | 2        |
| cAdvisor   | gcr.io/cadvisor/cadvisor:latest        | 1/nœud   |

## Prérequis

- minikube (2 nœuds minimum)
- kubectl

```bash
minikube start --nodes 2
```

## Déploiement

```bash
# 1. Monitoring
kubectl apply -f monitoring/cadvisor.daemonset.yaml

# 2. PostgreSQL
kubectl apply -f Db/postgres/postgres.secret.yaml \
              -f Db/postgres/postgres.configmap.yaml \
              -f Db/postgres/postgres.volume.yaml \
              -f Db/postgres/postgres.statefulset.yaml \
              -f Db/postgres/postgres.service.yaml

# 3. Redis
kubectl apply -f Db/redis/redis.volume.yaml \
              -f Db/redis/redis.configmap.yaml \
              -f Db/redis/redis.statefulset.yaml \
              -f Db/redis/redis.service.yaml

# 4. Services applicatifs
kubectl apply -f services/poll.deployment.yaml \
              -f services/worker.deployment.yaml \
              -f services/result.deployment.yaml \
              -f services/poll.service.yaml \
              -f services/result.service.yaml \
              -f services/poll.ingress.yaml \
              -f services/result.ingress.yaml

# 5. Load balancer
kubectl apply -f load_balancer/traefik.rbac.yaml

# 6. Créer la table votes
echo "CREATE TABLE votes (id text PRIMARY KEY, vote text NOT NULL);" | \
  kubectl exec -i postgres-0 -- psql -U admin -d vote

# 7. Ajouter les entrées DNS locales
echo "$(kubectl get nodes -o jsonpath='{ $.items[*].status.addresses[?(@.type=="InternalIP")].address }') poll.dop.io result.dop.io" \
  | sudo tee -a /etc/hosts
```

## Accès

| Service           | URL                        |
|-------------------|----------------------------|
| Application vote  | http://poll.dop.io:30021   |
| Résultats         | http://result.dop.io:30021 |
| Dashboard Traefik | http://localhost:30042      |
| cAdvisor          | `kubectl port-forward -n kube-system daemonset/cadvisor 8080:8080` |

## Structure du dépôt

```
.
├── Db/
│   ├── postgres/      # StatefulSet, ConfigMap, Secret, Service, PV
│   └── redis/         # StatefulSet, ConfigMap, Service, PV
├── services/          # Deployments, Services, Ingress (poll, worker, result)
├── load_balancer/     # Traefik RBAC
└── monitoring/        # cAdvisor DaemonSet
```
