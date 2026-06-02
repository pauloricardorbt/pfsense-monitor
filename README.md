# pfSense Monitor

Stack de monitoramento de firewall pfSense com alertas em tempo real via Google Chat.
Projeto independente, pode ser iniciado e parado sem afetar outros serviços de monitoramento.

---

## Visão Geral

```
pfSense (<PFSENSE_IP>)
  ├── SNMP :161 ──────────► snmp-exporter ──► prometheus ──► grafana
  ├── Syslog UDP :514 ────► syslog-ng ──► n8n ──► Google Chat
  └── Ping (blackbox) ───► prometheus ──► grafana ──► n8n ──► Google Chat
```

---

## Alertas Configurados

### Via Syslog — eventos em tempo real

| Ícone | Evento | Origem |
|-------|--------|--------|
| 🔴 | Link WAN CAIU | dpinger |
| ✅ | Link WAN RECUPERADO | dpinger |
| 🚨 | TENTATIVA DE INVASÃO — SSH (senha errada) + IP + usuário | sshd |
| 🚨 | TENTATIVA DE INVASÃO — SSH (usuário inválido) + IP | sshd |
| 🔑 | Login SSH realizado + IP + usuário | sshd |
| 🔍 | Varredura SSH detectada + IP | sshd |
| 🚨 | TENTATIVA DE INVASÃO — Painel Web + IP + usuário | php |
| 🔑 | Login no Painel Web + IP + usuário | php |
| 🚫 | IP BLOQUEADO pelo Login Protection + duração | php |
| 🆘 | IDS/IPS — Alerta Crítico Snort (P1) + tráfego | snort |
| 🛡️ | IDS/IPS — Alerta Alto Snort (P2) + tráfego | snort |
| 🔍 | Acesso bloqueado em porta sensível + IP + porta | filterlog |
| 🔴 | Erro crítico do sistema | qualquer |
| ⚙️ | Configuração do pfSense alterada | php |

### Via Grafana — baseado em métricas

| Alerta | Condição | Severidade |
|--------|----------|------------|
| 🔴 WAN Link Offline | ping falha por 1 min | critical |
| ⚠️ Latência Alta | > 150ms por 2 min | warning |
| ⚠️ CPU Alta | idle < 20% por 5 min | warning |
| ⚠️ Memória Alta | livre < 15% por 5 min | warning |
| 🔴 Interface Down | ifOperStatus ≠ up por 2 min | critical |

---

## Estrutura do Projeto

```
pfsense-monitor/
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml                  # scrape SNMP + blackbox probes
├── snmp-exporter/
│   └── snmp.yml                        # módulo pfSense (CPU, RAM, interfaces)
├── blackbox/
│   └── blackbox.yml                    # probe ICMP para gateways e internet
├── syslog-ng/
│   └── syslog-ng.conf                  # filtros: SSH, WebGUI, Snort, dpinger
├── grafana/
│   └── provisioning/
│       ├── datasources/prometheus.yml
│       ├── dashboards/dashboard.yml
│       └── alerting/alerts.yml         # regras + contact point n8n
├── n8n/
│   ├── workflow-grafana-alerts.json    # Grafana → Google Chat
│   └── workflow-syslog-alerts.json     # Syslog → Google Chat
├── .env.example                        # variáveis necessárias (sem valores)
├── .gitignore
├── instalar.sh                         # deploy automatizado no servidor
├── README.md
└── DOCUMENTACAO.md                     # documentação técnica completa
```

---

## Containers

| Container | Porta | Função |
|-----------|-------|--------|
| `prometheus-pfsense` | 9091 | Coleta e armazena métricas |
| `snmp-exporter-pfsense` | interno | Traduz SNMP → Prometheus |
| `blackbox-pfsense` | interno | Ping nos gateways e internet |
| `syslog-ng-pfsense` | 514/udp, 601/tcp | Recebe e filtra syslog do pfSense |
| `grafana-pfsense` | 3001 | Dashboard e alertas |

---

## Pré-requisitos

- pfSense 2.7.x com **SNMP habilitado** (porta 161, community configurada)
- Servidor Linux com **Docker + Docker Compose v2**
- **n8n** rodando e acessível na rede
- Espaço no **Google Chat** com webhook configurado

---

## Instalação

### 1. Configurar variáveis

```bash
cp .env.example .env
# Editar .env com os valores reais do seu ambiente
```

### 2. Ajustar arquivos de configuração

Antes de subir, substitua os placeholders nos arquivos:

| Arquivo | Placeholder | Substituir por |
|---------|-------------|----------------|
| `prometheus/prometheus.yml` | `<PFSENSE_IP>` | IP do seu pfSense |
| `prometheus/prometheus.yml` | `<WAN_DEFAULT_GW_IP>` | IP do gateway padrão |
| `grafana/provisioning/alerting/alerts.yml` | `<PFSENSE_IP>` | IP do seu pfSense |
| `grafana/provisioning/alerting/alerts.yml` | `<N8N_URL>` | URL do seu n8n |
| `syslog-ng/syslog-ng.conf` | `<N8N_URL>` | URL do seu n8n |
| `n8n/workflow-*.json` | `<GOOGLE_CHAT_WEBHOOK_URL>` | Webhook do Google Chat |
| `docker-compose.yml` | `<MONITORING_SERVER_IP>` | IP do servidor |

### 3. Copiar para o servidor e instalar

```bash
scp -r pfsense-monitor/ <USER>@<MONITORING_SERVER_IP>:/tmp/
ssh <USER>@<MONITORING_SERVER_IP>
bash /tmp/pfsense-monitor/instalar.sh
```

### 4. Subir os containers

```bash
cd /home/<USER>/monitoramento/pfsense
docker compose up -d
docker compose ps
```

### 5. Importar workflows no n8n

```bash
docker cp /caminho/para/workflow-grafana-alerts.json <N8N_CONTAINER>:/tmp/wf-g.json
docker cp /caminho/para/workflow-syslog-alerts.json <N8N_CONTAINER>:/tmp/wf-s.json
docker exec <N8N_CONTAINER> n8n import:workflow --input=/tmp/wf-g.json
docker exec <N8N_CONTAINER> n8n import:workflow --input=/tmp/wf-s.json
docker exec <N8N_CONTAINER> n8n publish:workflow --id=pfsense-grafana-01
docker exec <N8N_CONTAINER> n8n publish:workflow --id=pfsense-syslog-01
docker restart <N8N_CONTAINER>
```

### 6. Configurar syslog no pfSense

**Status → System Logs → Settings → Remote Logging**
- Enable: ✅
- Remote syslog server: `<MONITORING_SERVER_IP>`
- Porta: `514` (UDP)
- Selecionar todas as categorias

---

## Gerenciamento

```bash
# Parar (sem afetar outros serviços)
docker compose -f /caminho/pfsense/docker-compose.yml down

# Iniciar
docker compose -f /caminho/pfsense/docker-compose.yml up -d

# Logs em tempo real
docker compose -f /caminho/pfsense/docker-compose.yml logs -f

# Ver alertas recebidos do pfSense
docker exec syslog-ng-pfsense tail -f /var/log/pfsense/pfsense-alerts.log

# Recarregar Prometheus após editar prometheus.yml
curl -X POST http://<MONITORING_SERVER_IP>:9091/-/reload
```

---

## Observações Técnicas

- **SNMP Exporter v0.30.1+** exige `auth` como parâmetro de URL:
  `?module=pfsense&auth=<AUTH_NAME>`
- **Interfaces virtuais excluídas** dos alertas: `pflog0`, `pfsync0`, `enc0`, `pppoeX` — ficam DOWN por design no pfSense.
- **n8n v1+**: corpo do webhook em `$input.first().json.body`. O código usa `raw.body || raw` para compatibilidade.
- Gateways PPPoE com IP privado do ISP não respondem ICMP externamente — use syslog (dpinger) para detectar queda.

---

## Licença

Uso interno. Adapte livremente para seu ambiente.
