#!/usr/bin/env bash
#
# start.sh — Démarrage complet du projet Bernstein (T-DOP-603)
#
# Déploie l'app de vote sur minikube : monitoring, bases de données,
# services applicatifs, load balancer Traefik, puis expose les URLs.
#
# Usage :
#   ./start.sh                  # mot de passe postgres demandé interactivement
#   POSTGRES_PASSWORD=xxx ./start.sh   # mot de passe fourni par variable d'env
#
set -euo pipefail

# Se placer à la racine du projet (là où est ce script)
cd "$(dirname "$0")"

# ──────────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────────
POSTGRES_USER="${POSTGRES_USER:-admin}"
POSTGRES_DB="${POSTGRES_DB:-vote}"
HOSTS=("poll.dop.io" "result.dop.io")

# Couleurs
green() { printf "\033[0;32m%s\033[0m\n" "$1"; }
blue()  { printf "\033[0;34m%s\033[0m\n" "$1"; }
red()   { printf "\033[0;31m%s\033[0m\n" "$1"; }

# ──────────────────────────────────────────────────────────────
# 0. Mot de passe postgres
# ──────────────────────────────────────────────────────────────
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  read -rsp "Mot de passe PostgreSQL (POSTGRES_PASSWORD) : " POSTGRES_PASSWORD
  echo
fi

# ──────────────────────────────────────────────────────────────
# 1. minikube
# ──────────────────────────────────────────────────────────────
blue "==> Vérification de minikube..."
if ! minikube status >/dev/null 2>&1; then
  green "    minikube n'est pas démarré, lancement (2 nœuds)..."
  minikube start --nodes 2
else
  green "    minikube déjà démarré."
fi

# ──────────────────────────────────────────────────────────────
# 2. Monitoring (cAdvisor)
# ──────────────────────────────────────────────────────────────
blue "==> Déploiement du monitoring (cAdvisor)..."
kubectl apply -f monitoring/cadvisor.daemonset.yaml

# ──────────────────────────────────────────────────────────────
# 3. Secret PostgreSQL (gitignored, donc créé à la volée)
# ──────────────────────────────────────────────────────────────
blue "==> Création du secret postgres..."
kubectl create secret generic postgres-secret \
  --namespace default \
  --from-literal=user="$POSTGRES_USER" \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# ──────────────────────────────────────────────────────────────
# 4. PostgreSQL
# ──────────────────────────────────────────────────────────────
blue "==> Déploiement de PostgreSQL..."
kubectl apply -f Db/postgres/postgres.configmap.yaml \
              -f Db/postgres/postgres.volume.yaml \
              -f Db/postgres/postgres.statefulset.yaml \
              -f Db/postgres/postgres.service.yaml

# ──────────────────────────────────────────────────────────────
# 5. Redis
# ──────────────────────────────────────────────────────────────
blue "==> Déploiement de Redis..."
kubectl apply -f Db/redis/redis.volume.yaml \
              -f Db/redis/redis.configmap.yaml \
              -f Db/redis/redis.statefulset.yaml \
              -f Db/redis/redis.service.yaml

# ──────────────────────────────────────────────────────────────
# 6. Services applicatifs (poll, worker, result)
# ──────────────────────────────────────────────────────────────
blue "==> Déploiement des services applicatifs..."
kubectl apply -f services/poll.deployment.yaml \
              -f services/worker.deployment.yaml \
              -f services/result.deployment.yaml \
              -f services/poll.service.yaml \
              -f services/result.service.yaml \
              -f services/poll.ingress.yaml \
              -f services/result.ingress.yaml

# ──────────────────────────────────────────────────────────────
# 7. Load balancer (Traefik)
# ──────────────────────────────────────────────────────────────
blue "==> Déploiement de Traefik..."
kubectl apply -f load_balancer/traefik.rbac.yaml \
              -f load_balancer/traefik.deployment.yaml \
              -f load_balancer/traefik.service.yaml

# ──────────────────────────────────────────────────────────────
# 8. Attente que PostgreSQL soit prêt
# ──────────────────────────────────────────────────────────────
blue "==> Attente du pod postgres..."
kubectl wait pod -l app=postgres --for=condition=Ready --timeout=120s

# ──────────────────────────────────────────────────────────────
# 9. Création de la table votes (idempotent)
# ──────────────────────────────────────────────────────────────
blue "==> Création de la table 'votes'..."
echo "CREATE TABLE IF NOT EXISTS votes (id text PRIMARY KEY, vote text NOT NULL);" | \
  kubectl exec -i postgres-0 -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# ──────────────────────────────────────────────────────────────
# 10. Entrées /etc/hosts (127.0.0.1, car on passe par port-forward)
# ──────────────────────────────────────────────────────────────
blue "==> Vérification de /etc/hosts..."
for h in "${HOSTS[@]}"; do
  if ! grep -q "$h" /etc/hosts; then
    green "    Ajout de $h (sudo requis)..."
    echo "127.0.0.1  $h" | sudo tee -a /etc/hosts >/dev/null
  else
    green "    $h déjà présent."
  fi
done

# ──────────────────────────────────────────────────────────────
# 11. Attente que Traefik soit prêt
# ──────────────────────────────────────────────────────────────
blue "==> Attente de Traefik..."
kubectl wait pod -l app=traefik -n kube-public --for=condition=Ready --timeout=120s

# ──────────────────────────────────────────────────────────────
# 12. Port-forwards (driver Docker macOS : NodePort non routable directement)
# ──────────────────────────────────────────────────────────────
blue "==> Démarrage des port-forwards..."

# Nettoie d'éventuels port-forwards déjà en cours sur ces ports
for port in 30021 30042; do
  pid="$(lsof -ti:"$port" 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done

# Proxy HTTP (poll / result) sur 30021
kubectl port-forward -n kube-public svc/traefik 30021:80 >/tmp/pf-traefik-web.log 2>&1 &
# Dashboard Traefik sur 30042
kubectl port-forward -n kube-public svc/traefik 30042:8080 >/tmp/pf-traefik-dash.log 2>&1 &

sleep 3

# ──────────────────────────────────────────────────────────────
# Récapitulatif
# ──────────────────────────────────────────────────────────────
echo
green "✅ Déploiement terminé !"
echo
echo "  Application vote  → http://poll.dop.io:30021"
echo "  Résultats         → http://result.dop.io:30021"
echo "  Dashboard Traefik → http://localhost:30042/dashboard/"
echo
echo "  cAdvisor (monitoring), au besoin :"
echo "    kubectl port-forward -n kube-system daemonset/cadvisor 8082:8080"
echo "    → http://localhost:8082"
echo
red "  ⚠️  Les port-forwards tournent en arrière-plan (PID de ce shell)."
red "      Pour les arrêter : kill \$(lsof -ti:30021) \$(lsof -ti:30042)"
echo
