#!/bin/bash

# Script per gestire port forwarding dei servizi di monitoring

set -e

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configurazione porte
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
ALERTMANAGER_PORT=9093
NODEEXPORTER_PORT=9100

# PID files per tracking processi
PID_DIR="/tmp/k8s-monitoring-pids"
mkdir -p "$PID_DIR"

# Funzioni di logging
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Verifica se il namespace monitoring exists
check_monitoring_namespace() {
    if ! kubectl get namespace monitoring &> /dev/null; then
        error "Namespace 'monitoring' non trovato. Esegui prima setup-k8s-environment.sh"
        exit 1
    fi
}

# Verifica se i servizi sono disponibili
check_services() {
    local services=("prometheus-kube-prometheus-prometheus" "prometheus-grafana" "prometheus-kube-prometheus-alertmanager")
    
    for service in "${services[@]}"; do
        if ! kubectl get svc "$service" -n monitoring &> /dev/null; then
            error "Servizio '$service' non trovato nel namespace monitoring"
            return 1
        fi
    done
    return 0
}

# Avvia port forward per un servizio
start_port_forward() {
    local service=$1
    local local_port=$2
    local remote_port=$3
    local name=$4
    local pid_file="$PID_DIR/${name}.pid"
    
    # Controlla se già in esecuzione
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        warn "$name già in esecuzione (PID: $(cat "$pid_file"))"
        return 0
    fi
    
    log "Avvio port forward per $name..."
    kubectl port-forward -n monitoring "svc/$service" "$local_port:$remote_port" &> /dev/null &
    local pid=$!
    echo "$pid" > "$pid_file"
    
    # Attendi che il port forward sia attivo
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        info "$name disponibile su http://localhost:$local_port"
    else
        error "Errore nell'avvio del port forward per $name"
        rm -f "$pid_file"
        return 1
    fi
}

# Ferma port forward per un servizio
stop_port_forward() {
    local name=$1
    local pid_file="$PID_DIR/${name}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            log "$name fermato"
        else
            warn "$name non era in esecuzione"
        fi
        rm -f "$pid_file"
    else
        warn "File PID per $name non trovato"
    fi
}

# Avvia tutti i port forward
start_all() {
    log "Avvio tutti i port forward per monitoring..."
    
    check_monitoring_namespace
    if ! check_services; then
        error "Alcuni servizi non sono disponibili"
        exit 1
    fi
    
    start_port_forward "prometheus-kube-prometheus-prometheus" "$PROMETHEUS_PORT" "9090" "prometheus"
    start_port_forward "prometheus-grafana" "$GRAFANA_PORT" "80" "grafana"
    start_port_forward "prometheus-kube-prometheus-alertmanager" "$ALERTMANAGER_PORT" "9093" "alertmanager"
    
    echo ""
    show_status
    show_urls
}

# Ferma tutti i port forward
stop_all() {
    log "Fermo tutti i port forward..."
    
    stop_port_forward "prometheus"
    stop_port_forward "grafana"
    stop_port_forward "alertmanager"
    
    # Pulizia directory PID se vuota
    if [ -z "$(ls -A "$PID_DIR" 2>/dev/null)" ]; then
        rmdir "$PID_DIR" 2>/dev/null || true
    fi
}

# Mostra status dei port forward
show_status() {
    echo -e "\n${CYAN}=== STATUS PORT FORWARD ===${NC}"
    
    local services=("prometheus" "grafana" "alertmanager")
    local ports=("$PROMETHEUS_PORT" "$GRAFANA_PORT" "$ALERTMANAGER_PORT")
    
    for i in "${!services[@]}"; do
        local service="${services[$i]}"
        local port="${ports[$i]}"
        local pid_file="$PID_DIR/${service}.pid"
        
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} $service: ATTIVO (PID: $(cat "$pid_file"), Porta: $port)"
        else
            echo -e "${RED}✗${NC} $service: INATTIVO"
        fi
    done
}

# Mostra URLs di accesso
show_urls() {
    echo -e "\n${CYAN}=== URL DI ACCESSO ===${NC}"
    
    if [ -f "$PID_DIR/prometheus.pid" ] && kill -0 "$(cat "$PID_DIR/prometheus.pid")" 2>/dev/null; then
        echo -e "${BLUE}Prometheus:${NC} http://localhost:$PROMETHEUS_PORT"
    fi
    
    if [ -f "$PID_DIR/grafana.pid" ] && kill -0 "$(cat "$PID_DIR/grafana.pid")" 2>/dev/null; then
        echo -e "${BLUE}Grafana:${NC} http://localhost:$GRAFANA_PORT (admin/admin123)"
    fi
    
    if [ -f "$PID_DIR/alertmanager.pid" ] && kill -0 "$(cat "$PID_DIR/alertmanager.pid")" 2>/dev/null; then
        echo -e "${BLUE}Alertmanager:${NC} http://localhost:$ALERTMANAGER_PORT"
    fi
    
    echo ""
}

# Avvia servizio singolo
start_service() {
    local service=$1
    
    check_monitoring_namespace
    
    case "$service" in
        "prometheus")
            start_port_forward "prometheus-kube-prometheus-prometheus" "$PROMETHEUS_PORT" "9090" "prometheus"
            ;;
        "grafana")
            start_port_forward "prometheus-grafana" "$GRAFANA_PORT" "80" "grafana"
            ;;
        "alertmanager")
            start_port_forward "prometheus-kube-prometheus-alertmanager" "$ALERTMANAGER_PORT" "9093" "alertmanager"
            ;;
        *)
            error "Servizio '$service' non riconosciuto. Usa: prometheus, grafana, alertmanager"
            exit 1
            ;;
    esac
    
    show_urls
}

# Ferma servizio singolo
stop_service() {
    local service=$1
    
    case "$service" in
        "prometheus"|"grafana"|"alertmanager")
            stop_port_forward "$service"
            ;;
        *)
            error "Servizio '$service' non riconosciuto. Usa: prometheus, grafana, alertmanager"
            exit 1
            ;;
    esac
}

# Riavvia tutti i servizi
restart_all() {
    log "Riavvio tutti i port forward..."
    stop_all
    sleep 2
    start_all
}

# Mostra aiuto
show_help() {
    echo -e "${CYAN}Gestione Port Forward per Monitoring Kubernetes${NC}"
    echo ""
    echo "Uso: $0 [COMANDO] [SERVIZIO]"
    echo ""
    echo -e "${YELLOW}COMANDI:${NC}"
    echo "  start [servizio]    Avvia port forward (tutti i servizi se non specificato)"
    echo "  stop [servizio]     Ferma port forward (tutti i servizi se non specificato)"
    echo "  restart             Riavvia tutti i port forward"
    echo "  status              Mostra status dei port forward"
    echo "  urls                Mostra URL di accesso"
    echo "  help                Mostra questo aiuto"
    echo ""
    echo -e "${YELLOW}SERVIZI:${NC}"
    echo "  prometheus          Prometheus (porta $PROMETHEUS_PORT)"
    echo "  grafana             Grafana (porta $GRAFANA_PORT)"
    echo "  alertmanager        Alertmanager (porta $ALERTMANAGER_PORT)"
    echo ""
    echo -e "${YELLOW}ESEMPI:${NC}"
    echo "  $0 start            # Avvia tutti i servizi"
    echo "  $0 start grafana    # Avvia solo Grafana"
    echo "  $0 stop             # Ferma tutti i servizi"
    echo "  $0 status           # Mostra status"
    echo ""
    echo -e "${YELLOW}NOTE:${NC}"
    echo "- I processi vengono eseguiti in background"
    echo "- I PID sono salvati in $PID_DIR"
    echo "- Usa Ctrl+C per interrompere lo script, i port forward continueranno"
}

# Cleanup al termine dello script
cleanup() {
    echo ""
    log "Script terminato. I port forward rimangono attivi in background."
    log "Usa '$0 stop' per fermarli o '$0 status' per verificare lo stato."
}

# Trap per cleanup
trap cleanup EXIT

# Parsing argomenti
case "${1:-help}" in
    "start")
        if [ -n "$2" ]; then
            start_service "$2"
        else
            start_all
        fi
        ;;
    "stop")
        if [ -n "$2" ]; then
            stop_service "$2"
        else
            stop_all
        fi
        ;;
    "restart")
        restart_all
        ;;
    "status")
        show_status
        ;;
    "urls")
        show_urls
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        error "Comando '$1' non riconosciuto"
        echo ""
        show_help
        exit 1
        ;;
esac