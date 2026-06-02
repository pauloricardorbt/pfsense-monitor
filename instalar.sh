#!/bin/bash
# Instalador: Monitoramento pfSense
# Destino: /home/administrador/monitoramento/pfsense
set -e

PASTA="/home/administrador/monitoramento/pfsense"

echo "=== Criando estrutura em $PASTA ==="
mkdir -p "$PASTA"/{prometheus,snmp-exporter,blackbox,syslog-ng}
mkdir -p "$PASTA"/grafana/provisioning/{datasources,dashboards,alerting}
mkdir -p "$PASTA"/grafana/dashboards
mkdir -p "$PASTA"/n8n

# ── docker-compose.yml ────────────────────────────────────────────────────────
cat > "$PASTA/docker-compose.yml" <<'EOF'
version: '3.8'

services:

  prometheus-pfsense:
    image: prom/prometheus:latest
    container_name: prometheus-pfsense
    restart: unless-stopped
    ports:
      - "9091:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_pfsense_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.enable-lifecycle'

  snmp-exporter:
    image: prom/snmp-exporter:latest
    container_name: snmp-exporter-pfsense
    restart: unless-stopped
    volumes:
      - ./snmp-exporter/snmp.yml:/etc/snmp_exporter/snmp.yml
    command:
      - '--config.file=/etc/snmp_exporter/snmp.yml'

  blackbox-pfsense:
    image: prom/blackbox-exporter:latest
    container_name: blackbox-pfsense
    restart: unless-stopped
    cap_add:
      - NET_RAW
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox/blackbox.yml
    command:
      - '--config.file=/etc/blackbox/blackbox.yml'

  syslog-ng-pfsense:
    image: balabit/syslog-ng:latest
    container_name: syslog-ng-pfsense
    restart: unless-stopped
    ports:
      - "514:514/udp"
      - "601:601/tcp"
    volumes:
      - ./syslog-ng/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf
      - syslog_pfsense_data:/var/log/pfsense

  grafana-pfsense:
    image: grafana/grafana:latest
    container_name: grafana-pfsense
    restart: unless-stopped
    ports:
      - "3001:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=sbi@pfsense2024
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_UNIFIED_ALERTING_ENABLED=true
      - GF_ALERTING_ENABLED=false
      - GF_SERVER_ROOT_URL=http://10.1.2.253:3001
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/pfsense.json
    volumes:
      - grafana_pfsense_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    depends_on:
      - prometheus-pfsense

volumes:
  prometheus_pfsense_data:
  grafana_pfsense_data:
  syslog_pfsense_data:
EOF

# ── prometheus/prometheus.yml ─────────────────────────────────────────────────
cat > "$PASTA/prometheus/prometheus.yml" <<'EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:

  - job_name: 'pfsense-snmp'
    metrics_path: /snmp
    params:
      module: [pfsense]
    static_configs:
      - targets: ['10.1.2.254']
        labels:
          device: 'pfSense'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: snmp-exporter:9116

  - job_name: 'pfsense-gateways'
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets: ['10.45.0.1']
        labels:
          gateway: 'WAN_HOKINET'
          provider: 'Hokinet'
      - targets: ['179.127.143.151']
        labels:
          gateway: 'WAN_MHNET'
          provider: 'MHNet (padrão)'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-pfsense:9115

  - job_name: 'pfsense-internet'
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets: ['1.1.1.1']
        labels:
          gateway: 'cloudflare'
          provider: 'Internet'
      - targets: ['8.8.8.8']
        labels:
          gateway: 'google_dns'
          provider: 'Internet'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-pfsense:9115
EOF

# ── snmp-exporter/snmp.yml ────────────────────────────────────────────────────
cat > "$PASTA/snmp-exporter/snmp.yml" <<'EOF'
auths:
  public_v2:
    community: public
    security_level: noAuthNoPriv
    version: 2

modules:
  pfsense:
    auth: public_v2
    walk:
      - 1.3.6.1.2.1.1.3
      - 1.3.6.1.2.1.2.2
      - 1.3.6.1.2.1.31.1.1
      - 1.3.6.1.4.1.2021.4
      - 1.3.6.1.4.1.2021.11
      - 1.3.6.1.2.1.25.2.3
      - 1.3.6.1.2.1.25.3.3
    metrics:
      - name: sysUpTime
        oid: 1.3.6.1.2.1.1.3.0
        type: gauge
        help: Uptime do sistema
      - name: ifOperStatus
        oid: 1.3.6.1.2.1.2.2.1.8
        type: gauge
        help: Status operacional da interface (1=up, 2=down)
        indexes:
          - labelname: ifIndex
            type: gauge
        lookups:
          - labels: [ifIndex]
            labelname: ifDescr
            oid: 1.3.6.1.2.1.2.2.1.2
            type: DisplayString
      - name: ifInOctets
        oid: 1.3.6.1.2.1.2.2.1.10
        type: counter
        help: Bytes recebidos
        indexes:
          - labelname: ifIndex
            type: gauge
        lookups:
          - labels: [ifIndex]
            labelname: ifDescr
            oid: 1.3.6.1.2.1.2.2.1.2
            type: DisplayString
      - name: ifOutOctets
        oid: 1.3.6.1.2.1.2.2.1.16
        type: counter
        help: Bytes enviados
        indexes:
          - labelname: ifIndex
            type: gauge
        lookups:
          - labels: [ifIndex]
            labelname: ifDescr
            oid: 1.3.6.1.2.1.2.2.1.2
            type: DisplayString
      - name: ssCpuUser
        oid: 1.3.6.1.4.1.2021.11.9.0
        type: gauge
        help: CPU usuário %
      - name: ssCpuSystem
        oid: 1.3.6.1.4.1.2021.11.10.0
        type: gauge
        help: CPU sistema %
      - name: ssCpuIdle
        oid: 1.3.6.1.4.1.2021.11.11.0
        type: gauge
        help: CPU idle %
      - name: memTotalReal
        oid: 1.3.6.1.4.1.2021.4.5.0
        type: gauge
        help: Memória total (KB)
      - name: memAvailReal
        oid: 1.3.6.1.4.1.2021.4.6.0
        type: gauge
        help: Memória disponível (KB)
EOF

# ── blackbox/blackbox.yml ─────────────────────────────────────────────────────
cat > "$PASTA/blackbox/blackbox.yml" <<'EOF'
modules:
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4
EOF

# ── syslog-ng/syslog-ng.conf ──────────────────────────────────────────────────
cat > "$PASTA/syslog-ng/syslog-ng.conf" <<'EOF'
@version: 3.38
@include "scl.conf"

source s_pfsense {
    udp(ip(0.0.0.0) port(514) flags(no-multi-line));
    tcp(ip(0.0.0.0) port(601) flags(no-multi-line));
};

filter f_gateway_alarm {
    program("dpinger") and (
        message("Alarm latency") or
        message("Alarm loss") or
        message("Alarm cleared") or
        message("Loss 100%")
    );
};

filter f_ssh_attack {
    program("sshd") and (
        message("Failed password") or
        message("Invalid user") or
        message("authentication failure") or
        message("Connection closed by invalid user") or
        message("Did not receive identification string") or
        message("Bad protocol version identification") or
        message("Unable to negotiate") or
        message("no matching key exchange method")
    );
};

filter f_ssh_success {
    program("sshd") and (
        message("Accepted password") or
        message("Accepted publickey")
    );
};

filter f_webgui_attack {
    program("php") and (
        message("webConfigurator authentication error") or
        message("GUI login failed") or
        message("authentication error for user")
    );
};

filter f_webgui_success {
    program("php") and (
        message("Successful login") or
        message("logged in successfully")
    );
};

filter f_ip_banned {
    program("php") and (
        message("has been banned") or
        message("blocked by login protection") or
        message("Too many failed login attempts")
    );
};

filter f_portscan {
    program("filterlog") and (
        message("block") or
        message("drop")
    ) and (
        message(":22:") or
        message(":23:") or
        message(":3389:") or
        message(":445:") or
        message(":1433:") or
        message(":3306:")
    );
};

filter f_snort {
    program("snort");
};

filter f_security {
    filter(f_ssh_attack) or
    filter(f_ssh_success) or
    filter(f_webgui_attack) or
    filter(f_webgui_success) or
    filter(f_ip_banned) or
    filter(f_portscan) or
    filter(f_snort);
};

filter f_critical {
    level(err..emerg);
};

filter f_config_change {
    message("config.xml") or
    (program("php") and message("configuration changed"));
};

filter f_pfsense_alert {
    filter(f_gateway_alarm) or
    filter(f_security) or
    filter(f_critical) or
    filter(f_config_change);
};

destination d_n8n {
    http(
        url("http://10.1.2.253:5678/webhook/pfsense-syslog")
        method("POST")
        body('{"host":"${HOST}","program":"${PROGRAM}","pid":"${PID}","message":"${MESSAGE}","priority":"${PRI}","facility":"${FACILITY}","level":"${LEVEL}","date":"${ISODATE}"}')
        headers("Content-Type: application/json")
        timeout(10)
        retries(3)
    );
};

destination d_file_all {
    file("/var/log/pfsense/pfsense-all.log"
        template("${ISODATE} ${HOST} ${PROGRAM}[${PID}]: ${MESSAGE}\n")
        owner("root") group("root") perm(0640)
        create-dirs(yes)
    );
};

destination d_file_alerts {
    file("/var/log/pfsense/pfsense-alerts.log"
        template("${ISODATE} ${HOST} ${PROGRAM}[${PID}]: ${MESSAGE}\n")
        owner("root") group("root") perm(0640)
        create-dirs(yes)
    );
};

log {
    source(s_pfsense);
    destination(d_file_all);
};

log {
    source(s_pfsense);
    filter(f_pfsense_alert);
    destination(d_n8n);
    destination(d_file_alerts);
};
EOF

# ── grafana/provisioning/datasources/prometheus.yml ───────────────────────────
cat > "$PASTA/grafana/provisioning/datasources/prometheus.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus-pfSense
    type: prometheus
    access: proxy
    uid: prometheus-pfsense
    url: http://prometheus-pfsense:9090
    isDefault: true
    jsonData:
      timeInterval: 30s
EOF

# ── grafana/provisioning/dashboards/dashboard.yml ─────────────────────────────
cat > "$PASTA/grafana/provisioning/dashboards/dashboard.yml" <<'EOF'
apiVersion: 1
providers:
  - name: pfSense
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF

echo ""
echo "=== Estrutura criada com sucesso! ==="
echo ""
echo "PRÓXIMOS PASSOS:"
echo "  1. Copiar os workflows n8n (pasta n8n/) para o n8n em http://10.1.2.253:5678"
echo "  2. Substituir SUBSTITUIR_WEBHOOK_GOOGLE_CHAT_PFSENSE pelo webhook do novo espaço"
echo "  3. Copiar grafana/provisioning/alerting/alerts.yml manualmente"
echo "  4. Configurar syslog no pfSense (10.1.2.254 → 10.1.2.253:514)"
echo "  5. Iniciar os containers:"
echo "     cd $PASTA && docker compose up -d"
echo ""
echo "Acesso após subir:"
echo "  Grafana pfSense:  http://10.1.2.253:3001  (admin / sbi@pfsense2024)"
echo "  Prometheus:       http://10.1.2.253:9091"
