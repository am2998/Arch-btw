#!/bin/bash

# Script per configurare ambiente Kubernetes base
# Include: Monitoring (Prometheus/Grafana), New Relic, Kyverno, Network Policies, Storage

set -e

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Funzione per logging
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verifica prerequisiti
check_prerequisites() {
    log "Verifico prerequisiti..."
    
    # Verifica kubectl
    if ! command -v kubectl &> /dev/null; then
        error "kubectl non trovato. Installalo prima di continuare."
        exit 1
    fi
    
    # Verifica helm
    if ! command -v helm &> /dev/null; then
        error "helm non trovato. Installalo prima di continuare."
        exit 1
    fi
    
    # Verifica connessione cluster
    if ! kubectl cluster-info &> /dev/null; then
        error "Impossibile connettersi al cluster Kubernetes."
        exit 1
    fi
    
    log "Prerequisiti verificati con successo"
}

# Installa New Relic
install_newrelic() {
    log "Installazione New Relic..."
    
    # Verifica se la license key è impostata
    if [ -z "$NEW_RELIC_LICENSE_KEY" ]; then
        warn "NEW_RELIC_LICENSE_KEY non impostata. Saltando installazione New Relic."
        warn "Per installare New Relic, esporta la variabile: export NEW_RELIC_LICENSE_KEY=your_license_key"
        return 0
    fi
    
    # Aggiungi repository Helm
    helm repo add newrelic https://helm-charts.newrelic.com >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # Crea namespace
    kubectl create namespace newrelic --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    
    # Installa New Relic Bundle (in background)
    log "Avvio deployment New Relic Bundle..."
    helm upgrade --install newrelic-bundle newrelic/nri-bundle \
        --namespace newrelic \
        --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
        --set global.cluster="$(kubectl config current-context)" \
        --set newrelic-infrastructure.privileged=true \
        --set global.lowDataMode=true \
        --set kube-state-metrics.enabled=true \
        --set kubeEvents.enabled=true \
        --set newrelic-prometheus-agent.enabled=true \
        --set newrelic-prometheus-agent.lowDataMode=true \
        --set logging.enabled=true \
        --set newrelic-logging.lowDataMode=true \
        --timeout=10m >/dev/null 2>&1 &
    
    log "New Relic Bundle deployment avviato"
}

# Installa Prometheus stack
install_prometheus() {
    log "Installazione Prometheus stack..."
    
    # Aggiungi repository Helm
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # Crea namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    
    # Installa Prometheus
    log "Avvio deployment Prometheus stack..."
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
        --set prometheus.prometheusSpec.retention=15d \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.size=5Gi \
        --set grafana.adminPassword=admin123 \
        --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=5Gi \
        --set nodeExporter.enabled=false \
        --timeout=15m >/dev/null 2>&1 &
    
    log "Prometheus stack deployment avviato"
}

# Configura accesso Grafana
setup_grafana_access() {
    log "Configurazione accesso Grafana..."
    
    # Crea service per accesso esterno (NodePort)
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Service
metadata:
  name: grafana-external
  namespace: monitoring
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 3000
    nodePort: 30300
  selector:
    app.kubernetes.io/name: grafana
EOF
    
    log "Service Grafana NodePort configurato"
}

# Configura storage
setup_storage() {
    log "Configurazione storage..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Applica storage se esiste
    if [ -f "$SCRIPT_DIR/storage/hostpath-storageclass.yaml" ]; then
        kubectl apply -f "$SCRIPT_DIR/storage/" >/dev/null 2>&1 || warn "Alcuni storage potrebbero non essere stati applicati"
        log "Storage configurato"
    else
        warn "File storage non trovato, uso configurazione di default"
    fi
}

# Installa Falco
install_falco() {
    log "Installazione Falco..."
    
    # Aggiungi repository Helm
    helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # Crea namespace
    kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    
    # Installa Falco (in background)
    log "Avvio deployment Falco..."
    helm upgrade --install falco falcosecurity/falco \
        --namespace falco \
        --set falco.grpc.enabled=true \
        --set falco.grpcOutput.enabled=true \
        --set falco.httpOutput.enabled=true \
        --set falco.jsonOutput=true \
        --set falco.logLevel=info \
        --set falco.syscallEventDrops.actions="log,alert" \
        --set falco.priority=debug \
        --set resources.requests.cpu=100m \
        --set resources.requests.memory=512Mi \
        --set resources.limits.memory=1Gi \
        --timeout=10m >/dev/null 2>&1 &
    
    log "Falco deployment avviato"
}

# Installa Kyverno
install_kyverno() {
    log "Installazione Kyverno..."
    
    # Aggiungi repository Helm
    helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # Crea namespace
    kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    
    # Installa Kyverno (in background)
    log "Avvio deployment Kyverno..."
    helm upgrade --install kyverno kyverno/kyverno \
        --namespace kyverno \
        --set replicaCount=1 \
        --set resources.limits.memory=512Mi \
        --set resources.requests.memory=256Mi \
        --timeout=10m >/dev/null 2>&1 &
    
    log "Kyverno deployment avviato"
}

# Installa Rancher Docker container
install_rancher() {
    log "Installazione Rancher Docker container..."
    
    # Verifica se Docker è disponibile
    if ! command -v docker &> /dev/null; then
        warn "Docker non trovato. Saltando installazione Rancher."
        return 0
    fi
    
    # Ferma container esistente se presente
    docker stop rancher 2>/dev/null || true
    docker rm rancher 2>/dev/null || true
    
    # Crea directory per audit logs
    mkdir -p /tmp/rancher-audit-logs
    
    # Avvia Rancher con audit logging abilitato
    log "Avvio container Rancher con audit logging..."
    docker run -d --restart=unless-stopped \
        --name rancher \
        -p 80:80 -p 443:443 \
        -v /tmp/rancher-audit-logs:/var/log/audit \
        -e CATTLE_FEATURES="audit-log=true" \
        -e AUDIT_LEVEL=2 \
        -e AUDIT_LOG_PATH=/var/log/audit/audit.log \
        -e AUDIT_LOG_MAXAGE=30 \
        -e AUDIT_LOG_MAXBACKUP=10 \
        -e AUDIT_LOG_MAXSIZE=100 \
        --privileged \
        rancher/rancher:latest >/dev/null 2>&1 &
    
    log "Rancher container avviato con audit logging"
    log "Audit logs disponibili in: /tmp/rancher-audit-logs/"
}

# Applica Kyverno policies
apply_kyverno_policies() {
    log "Applicazione Kyverno policies..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -d "$SCRIPT_DIR/kyverno-policies" ]; then
        kubectl apply -f "$SCRIPT_DIR/kyverno-policies/" >/dev/null 2>&1 || warn "Alcune policy potrebbero non essere state applicate"
        log "Kyverno policies applicate"
    else
        warn "Directory kyverno-policies non trovata"
    fi
}

# Applica network policies
apply_network_policies() {
    log "Applicazione network policies..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -d "$SCRIPT_DIR/network-policies" ]; then
        kubectl apply -f "$SCRIPT_DIR/network-policies/" >/dev/null 2>&1 || warn "Alcune network policy potrebbero non essere state applicate"
        log "Network policies applicate"
    else
        warn "Directory network-policies non trovata"
    fi
}

# Verifica stato componenti con colori
check_component_status() {
    local namespace=$1
    local component=$2
    local selector=$3
    
    echo -n "  $component: "
    
    local pods=$(kubectl get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null)
    if [ -z "$pods" ]; then
        echo -e "${RED}NON TROVATO${NC}"
        return 1
    fi
    
    local running=$(echo "$pods" | grep -c "Running" || true)
    local total=$(echo "$pods" | wc -l)
    local pending=$(echo "$pods" | grep -c "Pending\|ContainerCreating" || true)
    local failed=$(echo "$pods" | grep -c "Error\|CrashLoopBackOff\|ImagePullBackOff" || true)
    
    if [ "$running" -eq "$total" ]; then
        echo -e "${GREEN}PRONTO ($running/$total)${NC}"
        return 0
    elif [ "$failed" -gt 0 ]; then
        echo -e "${RED}FAILED ($running/$total, $failed errori)${NC}"
        return 1
    else
        echo -e "${YELLOW}IN CORSO ($running/$total, $pending in attesa)${NC}"
        return 2
    fi
}

# Verifica installazioni con status colorato
verify_installations() {
    log "Verifica stato componenti..."
    
    echo -e "\n${BLUE}=== STATUS NEW RELIC ===${NC}"
    check_component_status "newrelic" "Infrastructure" "app.kubernetes.io/name=newrelic-infrastructure"
    check_component_status "newrelic" "Kube State Metrics" "app.kubernetes.io/name=kube-state-metrics"
    check_component_status "newrelic" "Prometheus Agent" "app.kubernetes.io/name=newrelic-prometheus-agent"
    check_component_status "newrelic" "Logging" "app.kubernetes.io/name=newrelic-logging"
    
    echo -e "\n${BLUE}=== STATUS MONITORING ===${NC}"
    check_component_status "monitoring" "Prometheus" "app.kubernetes.io/name=prometheus"
    check_component_status "monitoring" "Grafana" "app.kubernetes.io/name=grafana"
    check_component_status "monitoring" "Alertmanager" "app.kubernetes.io/name=alertmanager"
    check_component_status "monitoring" "Kube State Metrics" "app.kubernetes.io/name=kube-state-metrics"
    
    echo -e "\n${BLUE}=== STATUS FALCO ===${NC}"
    check_component_status "falco" "Falco DaemonSet" "app.kubernetes.io/name=falco"
    
    echo -e "\n${BLUE}=== STATUS KYVERNO ===${NC}"
    check_component_status "kyverno" "Admission Controller" "app.kubernetes.io/component=admission-controller"
    check_component_status "kyverno" "Background Controller" "app.kubernetes.io/component=background-controller"
    check_component_status "kyverno" "Reports Controller" "app.kubernetes.io/component=reports-controller"
    check_component_status "kyverno" "Cleanup Controller" "app.kubernetes.io/component=cleanup-controller"
    
    echo -e "\n${BLUE}=== STORAGE CLASSES ===${NC}"
    kubectl get storageclass --no-headers 2>/dev/null | while read line; do
        local name=$(echo "$line" | awk '{print $1}')
        local default=$(echo "$line" | grep -q "(default)" && echo " (default)" || echo "")
        echo -e "  ${GREEN}✓${NC} $name$default"
    done
    
    echo -e "\n${BLUE}=== NETWORK POLICIES ===${NC}"
    local netpol_count=$(kubectl get networkpolicy --all-namespaces --no-headers 2>/dev/null | wc -l)
    if [ "$netpol_count" -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} $netpol_count network policies attive"
        kubectl get networkpolicy --all-namespaces --no-headers 2>/dev/null | while read line; do
            local ns=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            echo -e "    - $ns/$name"
        done
    else
        echo -e "  ${YELLOW}⚠${NC} Nessuna network policy trovata"
    fi
    
    echo -e "\n${BLUE}=== KYVERNO POLICIES ===${NC}"
    local kyverno_pol_count=$(kubectl get cpol --no-headers 2>/dev/null | wc -l)
    if [ "$kyverno_pol_count" -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} $kyverno_pol_count cluster policies attive"
        kubectl get cpol --no-headers 2>/dev/null | while read line; do
            local name=$(echo "$line" | awk '{print $1}')
            local ready=$(echo "$line" | awk '{print $4}')
            if [ "$ready" = "True" ]; then
                echo -e "    ${GREEN}✓${NC} $name"
            else
                echo -e "    ${YELLOW}⚠${NC} $name (non pronto)"
            fi
        done
    else
        echo -e "  ${YELLOW}⚠${NC} Nessuna cluster policy trovata"
    fi
    
    echo -e "\n${BLUE}=== RANCHER CONTAINER ===${NC}"
    if docker ps --format "table {{.Names}}\t{{.Status}}" | grep -q "rancher"; then
        local rancher_status=$(docker ps --format "{{.Status}}" --filter "name=rancher")
        echo -e "  ${GREEN}✓${NC} Rancher container: $rancher_status"
        echo -e "  ${BLUE}URL:${NC} https://localhost (primo accesso per setup)"
        echo -e "  ${BLUE}Audit logs:${NC} /tmp/rancher-audit-logs/"
    else
        echo -e "  ${YELLOW}⚠${NC} Rancher container non in esecuzione"
    fi
}

# Mostra informazioni di accesso
show_access_info() {
    log "Informazioni di accesso:"
    
    echo -e "\n${BLUE}=== NEW RELIC ===${NC}"
    if [ -n "$NEW_RELIC_LICENSE_KEY" ]; then
        echo "Dashboard: https://one.newrelic.com"
        echo "Cluster: $(kubectl config current-context)"
        echo "License Key: ${NEW_RELIC_LICENSE_KEY:0:8}..."
    else
        echo "Non installato (NEW_RELIC_LICENSE_KEY non impostata)"
    fi
    
    echo -e "\n${BLUE}=== GRAFANA ===${NC}"
    echo "URL NodePort: http://<NODE-IP>:30300"
    echo "URL Port-Forward: http://localhost:3000"
    echo "Username: admin"
    echo "Password: admin123"
    
    echo -e "\n${BLUE}=== PROMETHEUS & ALERTMANAGER ===${NC}"
    echo "Prometheus: http://localhost:9090 (con port-forward)"
    echo "Alertmanager: http://localhost:9093 (con port-forward)"
    
    echo -e "\n${BLUE}=== FALCO ===${NC}"
    echo "Logs: kubectl logs -n falco -l app.kubernetes.io/name=falco"
    echo "Events: kubectl get events -n falco"
    
    echo -e "\n${BLUE}=== RANCHER ===${NC}"
    if docker ps --filter "name=rancher" --format "{{.Names}}" | grep -q "rancher"; then
        echo "URL: https://localhost"
        echo "Audit logs: /tmp/rancher-audit-logs/audit.log"
        echo "Container logs: docker logs rancher"
    else
        echo "Container non in esecuzione"
    fi
    
    echo -e "\n${BLUE}=== COMANDI UTILI ===${NC}"
    echo "Port forward: ./monitoring-portfwd.sh start"
    echo "Verifica completa: kubectl get pods --all-namespaces"
    echo "Cleanup completo: ./cleanup-k8s-environment.sh"
    
    echo -e "\n${BLUE}=== TEST KYVERNO ===${NC}"
    echo "Test policy privileged:"
    echo "kubectl run test-privileged --image=nginx --privileged"
    echo "(dovrebbe essere bloccato)"
}

# Attendi completamento deployment
wait_for_deployments() {
    log "Attendo completamento deployment (max 5 minuti)..."
    
    local max_wait=300  # 5 minuti
    local elapsed=0
    local interval=15
    
    while [ $elapsed -lt $max_wait ]; do
        echo -e "\n${CYAN}=== STATUS DOPO $elapsed SECONDI ===${NC}"
        verify_installations
        
        # Controlla se i componenti principali sono pronti
        local monitoring_ready=false
        local kyverno_ready=false
        
        # Verifica monitoring
        local monitoring_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -v "node-exporter" | grep "Running" | wc -l)
        local monitoring_total=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -v "node-exporter" | wc -l)
        if [ "$monitoring_pods" -eq "$monitoring_total" ] && [ "$monitoring_total" -gt 0 ]; then
            monitoring_ready=true
        fi
        
        # Verifica falco
        local falco_pods=$(kubectl get pods -n falco --no-headers 2>/dev/null | grep "Running" | wc -l)
        local falco_total=$(kubectl get pods -n falco --no-headers 2>/dev/null | wc -l)
        local falco_ready=true
        if [ "$falco_total" -gt 0 ] && [ "$falco_pods" -ne "$falco_total" ]; then
            falco_ready=false
        fi
        
        # Verifica kyverno (esclude job completati)
        local kyverno_pods=$(kubectl get pods -n kyverno --no-headers 2>/dev/null | grep "Running" | wc -l)
        local kyverno_total=$(kubectl get pods -n kyverno --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
        if [ "$kyverno_pods" -eq "$kyverno_total" ] && [ "$kyverno_total" -gt 0 ]; then
            kyverno_ready=true
        fi
        
        # Verifica newrelic (se installato)
        local newrelic_ready=true
        if [ -n "$NEW_RELIC_LICENSE_KEY" ]; then
            local newrelic_pods=$(kubectl get pods -n newrelic --no-headers 2>/dev/null | grep "Running" | wc -l)
            local newrelic_total=$(kubectl get pods -n newrelic --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
            if [ "$newrelic_total" -gt 0 ] && [ "$newrelic_pods" -ne "$newrelic_total" ]; then
                newrelic_ready=false
            fi
        fi
        
        if [ "$monitoring_ready" = true ] && [ "$kyverno_ready" = true ] && [ "$newrelic_ready" = true ] && [ "$falco_ready" = true ]; then
            log "Tutti i componenti principali sono pronti!"
            break
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if [ $elapsed -ge $max_wait ]; then
        warn "Timeout raggiunto. Alcuni componenti potrebbero ancora essere in fase di avvio."
    fi
}

# Test delle policy Kyverno
test_kyverno_policies() {
    log "Test delle policy Kyverno..."
    
    # Test 1: Container privilegiato (dovrebbe essere bloccato)
    echo -e "\n${YELLOW}Test 1: Container privilegiato (dovrebbe essere BLOCCATO)${NC}"
    if kubectl run test-privileged --image=nginx --dry-run=server -o yaml --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx","securityContext":{"privileged":true}}]}}' >/dev/null 2>&1; then
        echo -e "  ${RED}✗ FALLITO: Container privilegiato non bloccato${NC}"
    else
        echo -e "  ${GREEN}✓ SUCCESSO: Container privilegiato bloccato correttamente${NC}"
    fi
    
    # Test 2: Pod senza label (dovrebbe essere bloccato se policy attiva)
    echo -e "\n${YELLOW}Test 2: Pod senza label richieste${NC}"
    if kubectl run test-no-labels --image=nginx --dry-run=server >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠ Pod senza label accettato (policy potrebbe non essere configurata per bloccare)${NC}"
    else
        echo -e "  ${GREEN}✓ Pod senza label bloccato${NC}"
    fi
    
    # Cleanup eventuali pod di test
    kubectl delete pod test-privileged test-no-labels --ignore-not-found=true >/dev/null 2>&1
    
    echo -e "\n${BLUE}Policy Kyverno attive:${NC}"
    kubectl get cpol --no-headers | while read line; do
        local name=$(echo "$line" | awk '{print $1}')
        local ready=$(echo "$line" | awk '{print $4}')
        if [ "$ready" = "True" ]; then
            echo -e "  ${GREEN}✓${NC} $name"
        else
            echo -e "  ${YELLOW}⚠${NC} $name (non pronto)"
        fi
    done
}
# Funzione principale
main() {
    log "Avvio configurazione ambiente Kubernetes..."
    
    check_prerequisites
    
    # Installa componenti (monitoring prima per evitare interferenze)
    log "=== FASE 1: INSTALLAZIONE NEW RELIC ==="
    install_newrelic
    
    log "=== FASE 2: INSTALLAZIONE MONITORING ==="
    install_prometheus
    setup_grafana_access
    
    log "=== FASE 3: CONFIGURAZIONE STORAGE ==="
    setup_storage
    
    log "=== FASE 4: INSTALLAZIONE FALCO ==="
    install_falco
    
    log "=== FASE 5: INSTALLAZIONE KYVERNO ==="
    install_kyverno
    apply_kyverno_policies
    
    log "=== FASE 6: INSTALLAZIONE RANCHER ==="
    install_rancher
    
    log "=== FASE 7: NETWORK POLICIES ==="
    apply_network_policies
    
    # Attendi e verifica
    log "=== FASE 8: VERIFICA DEPLOYMENT ==="
    wait_for_deployments
    
    # Test policy se tutto è pronto
    if kubectl get pods -n kyverno --no-headers 2>/dev/null | grep -q "Running"; then
        log "=== FASE 9: TEST POLICY KYVERNO ==="
        test_kyverno_policies
    fi
    
    echo -e "\n${CYAN}=== CONFIGURAZIONE COMPLETATA ===${NC}"
    show_access_info
    
    log "Ambiente Kubernetes configurato con successo!"
    warn "Se alcuni componenti sono ancora 'IN CORSO'."
}

# Esegui script
main "$@"