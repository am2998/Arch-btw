#!/bin/bash

# Script per configurare ambiente Kubernetes base
# Include: Monitoring (Prometheus/Grafana), Kyverno, Network Policies, Storage

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
    
    echo -e "\n${BLUE}=== STATUS MONITORING ===${NC}"
    check_component_status "monitoring" "Prometheus" "app.kubernetes.io/name=prometheus"
    check_component_status "monitoring" "Grafana" "app.kubernetes.io/name=grafana"
    check_component_status "monitoring" "Alertmanager" "app.kubernetes.io/name=alertmanager"
    check_component_status "monitoring" "Kube State Metrics" "app.kubernetes.io/name=kube-state-metrics"
    
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
}

# Mostra informazioni di accesso
show_access_info() {
    log "Informazioni di accesso:"
    
    echo -e "\n${BLUE}=== GRAFANA ===${NC}"
    echo "URL NodePort: http://<NODE-IP>:30300"
    echo "URL Port-Forward: http://localhost:3000"
    echo "Username: admin"
    echo "Password: admin123"
    
    echo -e "\n${BLUE}=== PROMETHEUS & ALERTMANAGER ===${NC}"
    echo "Prometheus: http://localhost:9090 (con port-forward)"
    echo "Alertmanager: http://localhost:9093 (con port-forward)"
    
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
        
        # Verifica kyverno (esclude job completati)
        local kyverno_pods=$(kubectl get pods -n kyverno --no-headers 2>/dev/null | grep "Running" | wc -l)
        local kyverno_total=$(kubectl get pods -n kyverno --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
        if [ "$kyverno_pods" -eq "$kyverno_total" ] && [ "$kyverno_total" -gt 0 ]; then
            kyverno_ready=true
        fi
        
        if [ "$monitoring_ready" = true ] && [ "$kyverno_ready" = true ]; then
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
    log "=== FASE 1: INSTALLAZIONE MONITORING ==="
    install_prometheus
    setup_grafana_access
    
    log "=== FASE 2: CONFIGURAZIONE STORAGE ==="
    setup_storage
    
    log "=== FASE 3: INSTALLAZIONE KYVERNO ==="
    install_kyverno
    apply_kyverno_policies
    
    log "=== FASE 4: NETWORK POLICIES ==="
    apply_network_policies
    
    # Attendi e verifica
    log "=== FASE 5: VERIFICA DEPLOYMENT ==="
    wait_for_deployments
    
    # Test policy se tutto è pronto
    if kubectl get pods -n kyverno --no-headers 2>/dev/null | grep -q "Running"; then
        log "=== FASE 6: TEST POLICY KYVERNO ==="
        test_kyverno_policies
    fi
    
    echo -e "\n${CYAN}=== CONFIGURAZIONE COMPLETATA ===${NC}"
    show_access_info
    
    log "Ambiente Kubernetes configurato con successo!"
    warn "Se alcuni componenti sono ancora 'IN CORSO'."
}

# Esegui script
main "$@"