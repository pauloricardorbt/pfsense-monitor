# Documentação Técnica — pfSense Monitor

> **Atenção:** Este arquivo descreve a arquitetura e decisões técnicas do projeto.
> Dados sensíveis (IPs, senhas, webhooks) devem ser mantidos no arquivo `.env` local,
> que não é versionado. Consulte `.env.example` para ver quais variáveis são necessárias.

---

## 1. Objetivo

Monitorar um firewall pfSense 2.7.x com envio de alertas em tempo real para o Google Chat,
cobrindo:

- Queda e recuperação de links WAN
- Latência alta nos gateways
- Uso elevado de CPU e memória
- Interface física down
- Tentativas de invasão (SSH e painel web)
- IP bloqueado pelo Login Protection
- Alertas do IDS/IPS Snort
- Port scan em portas críticas
- Erros críticos de sistema
- Alterações de configuração

---

## 2. Arquitetura

```
pfSense (<PFSENSE_IP>)
  |
  |-- SNMP UDP 161 ──────────────► snmp-exporter ──► prometheus-pfsense
  |                                                          |
  |-- Syslog UDP 514 ────────────► syslog-ng-pfsense    avalia alertas
  |                                      |                   |
  |                               filtra críticos    grafana-pfsense
  |                                      |                   |
  |                              n8n webhook syslog  n8n webhook grafana
  |                                      |                   |
  |-- Ping probe ────────────────► blackbox-pfsense          ▼
       <WAN_GW_IP>, 1.1.1.1                        Google Chat — pfSense Monitor
       8.8.8.8
```

---

## 3. Stack Docker

> Localização no servidor: definida em instalação — ver `instalar.sh`

| Container | Porta externa | Função |
|-----------|--------------|--------|
| `prometheus-pfsense` | **9091** | Coleta e armazena métricas |
| `snmp-exporter-pfsense` | interno | Traduz SNMP → Prometheus |
| `blackbox-pfsense` | interno | Ping nos gateways e IPs de internet |
| `syslog-ng-pfsense` | **514/udp**, **601/tcp** | Recebe, filtra e encaminha logs |
| `grafana-pfsense` | **3001** | Dashboard e regras de alerta |

**Volumes persistentes:**
- `prometheus_pfsense_data` — séries temporais do Prometheus
- `grafana_pfsense_data` — dashboards e configurações do Grafana
- `syslog_pfsense_data` — logs em `/var/log/pfsense/`

**Motivo da stack separada:** pode ser parada/iniciada sem afetar outros serviços de monitoramento que rodam em paralelo no mesmo servidor.

---

## 4. Configurações Necessárias no pfSense

### 4.1 SNMP

| Campo | Valor |
|-------|-------|
| Status | Habilitado |
| Porta | 161 (UDP) |
| Community | `<SNMP_COMMUNITY>` |
| Módulos recomendados | mibii, netgraph, pf, hostres, ucd, regex |

### 4.2 Syslog Remoto

Configurar em **Status → System Logs → Settings → Remote Logging**:

| Campo | Valor |
|-------|-------|
| Enable | ✅ |
| Remote syslog server | `<MONITORING_SERVER_IP>` |
| Porta | 514 (UDP) |
| Categorias | Todas (ou: system, ppp, auth, vpn, dpinger, filter) |

### 4.3 Gateways

O projeto monitora os IPs dos gateways WAN via probe ICMP e via syslog (dpinger).

> **Atenção:** Gateways PPPoE com IP privado do ISP geralmente não respondem ICMP de fora.
> Nesses casos, a detecção de queda deve ser feita exclusivamente pelo syslog (dpinger),
> não pelo probe de ping. Remova esses IPs do job `pfsense-gateways` no `prometheus.yml`.

---

## 5. Métricas Coletadas via SNMP

| Métrica Prometheus | OID | Descrição |
|-------------------|-----|-----------|
| `sysUpTime` | 1.3.6.1.2.1.1.3.0 | Uptime do pfSense |
| `ifOperStatus` | 1.3.6.1.2.1.2.2.1.8 | Status de cada interface (1=up, 2=down) |
| `ifInOctets` / `ifOutOctets` | IF-MIB | Tráfego por interface (bytes) |
| `ifInErrors` / `ifOutErrors` | IF-MIB | Erros por interface |
| `ssCpuUser` / `ssCpuSystem` / `ssCpuIdle` | UCD-SNMP | CPU por modo (%) |
| `memTotalReal` / `memAvailReal` | UCD-SNMP | Memória física (KB) |
| `memTotalSwap` / `memAvailSwap` | UCD-SNMP | Swap (KB) |
| `hrProcessorLoad` | HOST-RESOURCES-MIB | Utilização por core CPU (%) |

> **Nota técnica — snmp-exporter v0.26+:** o campo `auth` não fica mais dentro do
> módulo no `snmp.yml`. Deve ser passado como parâmetro de URL no `prometheus.yml`:
> ```yaml
> params:
>   module: [pfsense]
>   auth: [<AUTH_NAME>]
> ```

---

## 6. Probes de Conectividade (Blackbox)

O blackbox exporter faz probe ICMP (ping) nos seguintes targets:

**Job `pfsense-gateways`** — detecta queda dos links WAN:
- `<WAN_DEFAULT_GW_IP>` — gateway padrão

**Job `pfsense-internet`** — valida conectividade com a internet:
- `1.1.1.1` — Cloudflare DNS
- `8.8.8.8` — Google DNS

---

## 7. Alertas do Grafana

**Contact Point:** `<N8N_URL>/webhook/pfsense-grafana-alert`

### Grupo: Links WAN

| Alerta | Condição PromQL | Duração | Severidade |
|--------|----------------|---------|------------|
| WAN Link Offline | `probe_success{job="pfsense-gateways"} < 1` | 1 min | critical |
| Latência Alta | `probe_duration_seconds{job="pfsense-gateways"}*1000 > 150` | 2 min | warning |

### Grupo: Recursos do Sistema

| Alerta | Condição PromQL | Duração | Severidade |
|--------|----------------|---------|------------|
| CPU Alta | `ssCpuIdle{instance="<PFSENSE_IP>"} < 20` | 5 min | warning |
| Memória Alta | `(memAvailReal/memTotalReal)*100 < 15` | 5 min | warning |

### Grupo: Interfaces

| Alerta | Condição PromQL | Duração | Severidade |
|--------|----------------|---------|------------|
| Interface Down | `ifOperStatus{ifDescr!~"lo.*\|pflog.*\|pfsync.*\|enc.*\|pppoe.*"} > 1` | 2 min | critical |

> As interfaces `pflog0`, `pfsync0`, `enc0` e `pppoeX` são excluídas pois ficam
> DOWN por design no pfSense e não representam falha real.

**Política:** repeat_interval = 2h (evita flood de mensagens repetidas).

---

## 8. Filtros do Syslog-ng

O pfSense envia syslog para `<MONITORING_SERVER_IP>:514`.
O syslog-ng filtra e envia ao n8n via HTTP POST apenas eventos relevantes.

| Filtro | Programa | O que detecta |
|--------|----------|---------------|
| `f_gateway_alarm` | dpinger | Alarm latency/loss/cleared — queda e recuperação de gateway |
| `f_ssh_attack` | sshd | Brute force e varredura SSH |
| `f_ssh_success` | sshd | Login SSH bem-sucedido |
| `f_webgui_attack` | php | Tentativa de login no painel web do pfSense |
| `f_webgui_success` | php | Login bem-sucedido no painel web |
| `f_ip_banned` | php | IP bloqueado automaticamente pelo Login Protection |
| `f_portscan` | filterlog | Bloqueios nas portas 22, 23, 3389, 445, 1433, 3306 |
| `f_snort` | snort | Qualquer alerta do IDS/IPS |
| `f_critical` | qualquer | Nível syslog: err, crit, alert, emerg |
| `f_config_change` | php | Alteração de configuração no pfSense |

**Arquivos de log no container:**
- `/var/log/pfsense/pfsense-all.log` — histórico completo de todos os logs
- `/var/log/pfsense/pfsense-alerts.log` — apenas eventos de alerta

---

## 9. Workflows n8n

### 9.1 Syslog → Google Chat

| Campo | Valor |
|-------|-------|
| ID | `pfsense-syslog-01` |
| Webhook | `/webhook/pfsense-syslog` |

Classifica automaticamente cada evento e monta mensagem formatada com ícone,
categoria, IP de origem, usuário e horário (fuso America/Sao_Paulo).

**Mapeamento de ícones:**

| Programa + padrão | Ícone | Categoria |
|-------------------|-------|-----------|
| dpinger + Loss 100% | 🔴 | Link WAN CAIU |
| dpinger + Alarm cleared | ✅ | Link WAN RECUPERADO |
| sshd + Failed password | 🚨 | TENTATIVA DE INVASÃO — SSH |
| sshd + Invalid user | 🚨 | TENTATIVA DE INVASÃO — SSH |
| sshd + Accepted | 🔑 | Login SSH Realizado |
| sshd + scan patterns | 🔍 | Varredura SSH Detectada |
| php + webConfigurator error | 🚨 | TENTATIVA DE INVASÃO — Painel Web |
| php + Successful login | 🔑 | Login no Painel Web |
| php + has been banned | 🚫 | IP BLOQUEADO — Login Protection |
| snort Priority 1 | 🆘 | IDS/IPS — ALERTA CRÍTICO |
| snort Priority 2 | 🛡️ | IDS/IPS — Alerta Alto |
| filterlog + block | 🔍 | Acesso Bloqueado em Porta Sensível |
| level err/crit/emerg | 🔴 | Erro Crítico do Sistema |

### 9.2 Grafana → Google Chat

| Campo | Valor |
|-------|-------|
| ID | `pfsense-grafana-01` |
| Webhook | `/webhook/pfsense-grafana-alert` |

Itera sobre o array `alerts[]` do payload do Grafana Alerting, formata
e envia com ícone de status (🔴 firing / ✅ resolved).

---

## 10. Problemas Encontrados e Soluções

### snmp-exporter: `field auth not found in type config.plain`

- **Causa:** v0.30.1+ não permite `auth` dentro do módulo no `snmp.yml`
- **Solução:** Remover `auth` do módulo; passar como parâmetro de URL no `prometheus.yml`:
  ```yaml
  params:
    module: [pfsense]
    auth: [public_v2]
  ```

### Probe ICMP em gateway PPPoE sempre retornando offline

- **Causa:** IPs PPPoE privados do ISP não respondem ICMP de redes externas
- **Solução:** Remover o probe direto no IP do gateway. Usar syslog/dpinger para detectar queda

### Alertas falsos para interfaces virtuais (pflog0, pfsync0)

- **Causa:** Essas interfaces ficam DOWN por design no pfSense
- **Solução:** Exclusão no PromQL: `ifDescr!~"lo.*|pflog.*|pfsync.*|enc.*|pppoe.*"`

### n8n: campos `program` e `message` chegando como `unknown`

- **Causa:** n8n v1+ encapsula o body do webhook em `.json.body`
- **Solução:**
  ```javascript
  const raw = $input.first().json;
  const event = raw.body || raw; // compatível com todas as versões
  ```

### n8n: HTTP Request não enviando JSON ao Google Chat

- **Causa:** Formato incorreto — nó httpRequest v4 espera `bodyParameters.parameters`
- **Solução:** Substituir `"body": {...}` por:
  ```json
  "bodyParameters": {
    "parameters": [{ "name": "text", "value": "={{ $json.text }}" }]
  }
  ```

---

## 11. Comandos de Gestão

```bash
# Parar a stack (sem afetar outros serviços de monitoramento)
docker compose -f /caminho/pfsense/docker-compose.yml down

# Iniciar
docker compose -f /caminho/pfsense/docker-compose.yml up -d

# Verificar status
docker compose -f /caminho/pfsense/docker-compose.yml ps

# Logs em tempo real
docker compose -f /caminho/pfsense/docker-compose.yml logs -f

# Ver alertas recebidos do pfSense
docker exec syslog-ng-pfsense tail -f /var/log/pfsense/pfsense-alerts.log

# Recarregar Prometheus após editar prometheus.yml
curl -X POST http://<MONITORING_SERVER_IP>:9091/-/reload

# Consultar métricas manualmente
curl -s 'http://<MONITORING_SERVER_IP>:9091/api/v1/query?query=ssCpuIdle'
curl -s 'http://<MONITORING_SERVER_IP>:9091/api/v1/query?query=probe_success{job="pfsense-gateways"}'
```

---

## 12. Dependências e Versões

| Componente | Versão testada |
|------------|---------------|
| pfSense | 2.7.2 Community Edition |
| Prometheus | latest (2.x) |
| SNMP Exporter | 0.30.1 |
| Blackbox Exporter | latest |
| Grafana | 13.0.1 |
| syslog-ng | 3.38 (balabit/syslog-ng:latest) |
| n8n | v1+ |
| Docker Compose | v2 |

---

## 13. Observações Finais

- **Telegraf:** se instalado no pfSense, verificar para onde está enviando métricas — pode ser reaproveitado como fonte adicional.
- **Snort / Zabbix:** se instalados no pfSense, estão disponíveis para expansão do monitoramento sem necessidade de nova stack.
- Os logs do pfSense persistem no volume Docker `syslog_pfsense_data` e sobrevivem a restarts dos containers.
- O arquivo `instalar.sh` recria toda a estrutura de arquivos no servidor a partir do zero.
