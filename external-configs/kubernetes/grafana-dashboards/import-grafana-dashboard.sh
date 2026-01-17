#!/bin/bash

# Script per importare dashboard Grafana personalizzate

set -e

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configurazione
GRAFANA_URL="http://localhost:3000"
GRAFANA_USER="admin"
GRAFANA_PASS="admin123"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$SCRIPT_DIR/grafana-dashboards"

# Verifica se Grafana è accessibile
check_grafana_access() {
    log "Verifico accesso a Grafana..."
    
    if ! curl -s -f "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
        error "Grafana non è accessibile su $GRAFANA_URL"
        error "Assicurati che il port-forward sia attivo: ./monitoring-portfwd.sh start"
        exit 1
    fi
    
    log "Grafana è accessibile"
}

# Importa una dashboard
import_dashboard() {
    local dashboard_file=$1
    local dashboard_name=$(basename "$dashboard_file" .json)
    
    log "Importo dashboard: $dashboard_name"
    
    # Leggi il file JSON
    local dashboard_json=$(cat "$dashboard_file")
    
    # Crea il payload per l'API
    local payload=$(cat <<EOF
{
  "dashboard": $dashboard_json,
  "overwrite": true,
  "inputs": [
    {
      "name": "DS_PROMETHEUS",
      "type": "datasource",
      "pluginId": "prometheus",
      "value": "prometheus"
    }
  ]
}
EOF
)
    
    # Importa la dashboard
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -u "$GRAFANA_USER:$GRAFANA_PASS" \
        -d "$payload" \
        "$GRAFANA_URL/api/dashboards/import" 2>/dev/null)
    
    if echo "$response" | grep -q '"status":"success"'; then
        local dashboard_url=$(echo "$response" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)
        log "Dashboard '$dashboard_name' importata con successo"
        echo "  URL: $GRAFANA_URL$dashboard_url"
    else
        warn "Errore nell'importazione di '$dashboard_name'"
        echo "  Response: $response"
    fi
}

# Crea datasource Prometheus se non esiste
setup_prometheus_datasource() {
    log "Verifico datasource Prometheus..."
    
    # Controlla se il datasource esiste già
    local existing=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" \
        "$GRAFANA_URL/api/datasources/name/prometheus" 2>/dev/null)
    
    if echo "$existing" | grep -q '"name":"prometheus"'; then
        log "Datasource Prometheus già configurato"
        return 0
    fi
    
    log "Creo datasource Prometheus..."
    
    # Crea il datasource
    local datasource_payload=$(cat <<EOF
{
  "name": "prometheus",
  "type": "prometheus",
  "url": "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090",
  "access": "proxy",
  "isDefault": true,
  "basicAuth": false
}
EOF
)
    
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -u "$GRAFANA_USER:$GRAFANA_PASS" \
        -d "$datasource_payload" \
        "$GRAFANA_URL/api/datasources" 2>/dev/null)
    
    if echo "$response" | grep -q '"message":"Datasource added"'; then
        log "Datasource Prometheus creato con successo"
    else
        warn "Errore nella creazione del datasource Prometheus"
        echo "  Response: $response"
    fi
}

# Importa tutte le dashboard
import_all_dashboards() {
    log "Importo tutte le dashboard da $DASHBOARD_DIR"
    
    if [ ! -d "$DASHBOARD_DIR" ]; then
        error "Directory dashboard non trovata: $DASHBOARD_DIR"
        exit 1
    fi
    
    local dashboard_count=0
    for dashboard_file in "$DASHBOARD_DIR"/*.json; do
        if [ -f "$dashboard_file" ]; then
            import_dashboard "$dashboard_file"
            ((dashboard_count++))
        fi
    done
    
    if [ $dashboard_count -eq 0 ]; then
        warn "Nessuna dashboard trovata in $DASHBOARD_DIR"
    else
        log "$dashboard_count dashboard importate"
    fi
}

# Mostra informazioni di accesso
show_access_info() {
    echo -e "\n${BLUE}=== ACCESSO GRAFANA ===${NC}"
    echo "URL: $GRAFANA_URL"
    echo "Username: $GRAFANA_USER"
    echo "Password: $GRAFANA_PASS"
    echo ""
    echo -e "${BLUE}=== DASHBOARD DISPONIBILI ===${NC}"
    echo "- Kubernetes Workload Monitoring: $GRAFANA_URL/d/workload-monitoring"
    echo ""
    echo -e "${BLUE}=== NOTE ===${NC}"
    echo "- Le dashboard sono configurate per escludere i namespace di sistema"
    echo "- Usa il filtro 'Namespace' per selezionare namespace specifici"
    echo "- Le metriche si aggiornano ogni 30 secondi"
}

# Funzione principale
main() {
    local command=${1:-"import"}
    
    case "$command" in
        "import")
            log "Avvio importazione dashboard Grafana..."
            check_grafana_access
            setup_prometheus_datasource
            import_all_dashboards
            show_access_info
            log "Importazione completata!"
            ;;
        "info")
            show_access_info
            ;;
        "help"|"-h"|"--help")
            echo "Uso: $0 [COMANDO]"
            echo ""
            echo "COMANDI:"
            echo "  import    Importa tutte le dashboard (default)"
            echo "  info      Mostra informazioni di accesso"
            echo "  help      Mostra questo aiuto"
            echo ""
            echo "PREREQUISITI:"
            echo "- Grafana deve essere accessibile su $GRAFANA_URL"
            echo "- Usa './monitoring-portforward.sh start' per il port-forward"
            ;;
        *)
            error "Comando '$command' non riconosciuto"
            echo "Usa '$0 help' per vedere i comandi disponibili"
            exit 1
            ;;
    esac
}

# Esegui script
main "$@"