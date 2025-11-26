#!/usr/bin/env bash

#==============================================================================
# INSTALLER V1.0 - Tracking Highend Production Stack (Compose + .env)
# Status: Versão de Lançamento Final com Fixes de Estabilidade e Automação.
# Objetivo: Deploy rápido de um Cluster N8N (Queue Mode) com Traefik (SSL) e DBs.
#==============================================================================

# Interrompe o script imediatamente se qualquer comando falhar.
set -e

# Cores e Formatação (Para melhor visualização no terminal)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
BLUE='\033[0;34m'

# Variáveis de Versão e Diretório
DOCKER_UBUNTU_VER="5:27.5.1-1~ubuntu.24.04~noble" # Versão específica para Ubuntu 24.04
DOCKER_FALLBACK_VER="5:27.5.1"                     # Versão de fallback para Debian
INSTALL_DIR="/opt/stack"                           # Diretório base para os arquivos de configuração

#==============================================================================
# Funções Auxiliares e Display
#==============================================================================

# Funções de Log customizadas
log_info() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}▶ $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# FUNÇÃO: Pausa Automática (Auto-Continue)
auto_continue() {
    local seconds=3
    echo -e "\n${YELLOW}${BOLD}>> PAUSA AUTOMÁTICA: Continuando em $seconds segundos... (Pressione Ctrl+C para cancelar)${NC}"
    sleep $seconds
    clear # Limpa a tela para a próxima etapa
}

# FUNÇÃO: Banner e Resumo Inicial
main_preamble() {
    clear
    echo -e "${MAGENTA}${BOLD}"
    cat << "EOF"
████████╗██╗  ██╗███████╗    ███████╗████████╗ █████╗  ██████╗██╗  ██╗
╚══██╔══╝██║  ██║██╔════╝    ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝
   ██║   ███████║█████╗      ███████╗   ██║   ███████║██║     █████╔╝
   ██║   ██║  ██║██╔══╝      ╚════██║   ██║   ██╔══██║██║     ██╔═██╗
   ██║   ██║  ██║███████╗    ███████║   ██║   ██║  ██║╚██████╗██║  ██╗
   ╚═╝   ╚═╝  ╚═╝╚══════╝    ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝

Tracking Highend - Master Installer (V1.0)
EOF
    echo -e "${NC}"

    echo -e "* ${RED}AVISO:${NC} antes de executar, libere os subdominios para instalação"
    echo -e "* ${YELLOW}SubDominios:${NC} n8n, traefik, portainer, webhook, pma"

    echo -e "\n${YELLOW}${BOLD}SETUP RESUMO:${NC}"
    echo -e "--------------------------------------------------------"
    echo -e "* ${GREEN}Orquestrador:${NC} Docker Compose"
    echo -e "* ${GREEN}Reverse Proxy:${NC} Traefik (v3) com Let's Encrypt (SSL/HTTPS)"
    echo -e "* ${GREEN}Serviços Principais:${NC} N8N (Editor, Webhook, Worker) em modo Cluster/Queue"
    echo -e "* ${GREEN}Bancos de Dados:${NC} PostgreSQL (N8N) e MySQL (Dados, porta 3306) + phpMyAdmin"
    echo -e "* ${GREEN}Gerenciador:${NC} Portainer (Web UI)"
    echo -e "--------------------------------------------------------"
    echo -e "${NC}"
    echo -e "${RED}${BOLD}PRÉ-REQUISITO:${NC} Execute como ROOT e configure o DNS antes do deploy."
    echo -e "\n${YELLOW}${BOLD}Pressione ENTER para iniciar a configuração dos domínios...${NC}"
}

# FUNÇÃO: Verifica se as portas 80, 443 e 3306 estão livres.
check_ports() {
    log_step "VERIFICANDO PORTAS (80, 443, 3306 e 5678)"

    # Verifica portas 80 (HTTP) e 443 (HTTPS)
    if lsof -i :80 > /dev/null 2>&1 || lsof -i :443 > /dev/null 2>&1; then
        log_warn "Portas 80 ou 443 em uso. Tentando parar serviços conflitantes (apache/nginx)..."
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
    fi

    # Verifica porta 3306 (MySQL)
    if lsof -i :3306 > /dev/null 2>&1; then
        log_warn "A porta 3306 (MySQL/MariaDB) está em uso no host. O MySQL do Docker pode ter conflitos."
    fi

    # Verifica porta 5678 (N8N Editor - Exposta por solicitação)
    if lsof -i :5678 > /dev/null 2>&1; then
        log_warn "A porta 5678 (N8N Editor) está em uso no host. O Editor do Docker não será acessível diretamente por esta porta."
    fi

    log_info "Verificação de portas concluída."
}

# FUNÇÃO: Atualiza o sistema e instala dependências básicas.
install_base_deps() {
    clear
    log_step "ETAPA 1/3: ATUALIZANDO SISTEMA BASE E INSTALANDO PRÉ-REQUISITOS"

    log_info "Executando apt update e upgrade..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    log_info "Instalando dependências essenciais (curl, gnupg, htpasswd)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release apache2-utils

    log_info "Sistema base pronto."
}

#==============================================================================
# 2. Coleta de Dados e Geração/Leitura de Segredos (Persistência)
#==============================================================================

collect_info() {
    log_step "CONFIGURAÇÃO DE DOMÍNIOS E SEGREDOS"

    # 2.1. Coleta de Domínio Base (Interativa)
    while true; do
        echo -n "Domínio principal (ex: empresa.com.br): "
        read -r BASE_DOMAIN
        if [[ "$BASE_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            echo -e "${RED}Formato inválido. Ex: nome.com.br${NC}"
        fi
    done

    # 2.2. Coleta de Subdomínios (Interativa com Padrão)
    echo -e "\n${CYAN}Definição de Subdomínios (Enter para manter o padrão):${NC}"

    read -p "Traefik Dashboard [traefik.$BASE_DOMAIN]: " SUB_TRAEFIK
    SUB_TRAEFIK=${SUB_TRAEFIK:-traefik}
    DOMAIN_TRAEFIK="${SUB_TRAEFIK}.${BASE_DOMAIN}"

    read -p "Portainer       [portainer.$BASE_DOMAIN]: " SUB_PORTAINER
    SUB_PORTAINER=${SUB_PORTAINER:-portainer}
    DOMAIN_PORTAINER="${SUB_PORTAINER}.${BASE_DOMAIN}"

    read -p "N8N Editor      [n8n.$BASE_DOMAIN]: " SUB_N8N
    SUB_N8N=${SUB_N8N:-n8n}
    DOMAIN_N8N="${SUB_N8N}.${BASE_DOMAIN}"

    read -p "N8N Webhook     [webhook.$BASE_DOMAIN]: " SUB_N8N_WEBHOOK
    SUB_N8N_WEBHOOK=${SUB_N8N_WEBHOOK:-webhook}
    DOMAIN_N8N_WEBHOOK="${SUB_N8N_WEBHOOK}.${BASE_DOMAIN}"

    read -p "phpMyAdmin      [pma.$BASE_DOMAIN]: " SUB_PMA
    SUB_PMA=${SUB_PMA:-pma}
    DOMAIN_PMA="${SUB_PMA}.${BASE_DOMAIN}"

    read -p "Email para SSL  [admin@$BASE_DOMAIN]: " EMAIL_SSL_VAL
    EMAIL_SSL_VAL=${EMAIL_SSL_VAL:-admin@${BASE_DOMAIN}}


    # 2.3. Lógica de Persistência de Segredos
    ENV_FILE="$INSTALL_DIR/.env"

    if [ -f "$ENV_FILE" ]; then
        log_warn "Arquivo .env existente. Reutilizando chaves de criptografia e senhas DB/Redis para ${BOLD}evitar perda de dados no N8N${NC}."

        # Carrega variáveis existentes para reutilização
        source "$ENV_FILE"

        POSTGRES_PASSWORD_N8N_VAL="${POSTGRES_PASSWORD_N8N}"
        MYSQL_ROOT_PASSWORD_VAL="${MYSQL_ROOT_PASSWORD}"
        MYSQL_USER_PASSWORD_VAL="${MYSQL_USER_PASSWORD}"
        N8N_ENCRYPTION_KEY_VAL="${N8N_ENCRYPTION_KEY}"
        REDIS_PASSWORD_VAL="${REDIS_PASSWORD}"
        TRAEFIK_DASH_PASS_RAW="${TRAEFIK_DASH_PASS_RAW}"
        TRAEFIK_BASIC_AUTH_VAL="${TRAEFIK_BASIC_AUTH}"

    else
        log_info "Gerando novos segredos criptográficos (primeira execução)..."
        # Geração de Senhas e Chaves
        POSTGRES_PASSWORD_N8N_VAL=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        MYSQL_ROOT_PASSWORD_VAL=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        MYSQL_USER_PASSWORD_VAL=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
        N8N_ENCRYPTION_KEY_VAL=$(openssl rand -base64 24)
        REDIS_PASSWORD_VAL=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)

        # Geração de Senha para Traefik Dashboard (Basic Auth)
        TRAEFIK_DASH_PASS_RAW=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)

        if command -v htpasswd >/dev/null; then
            # Cria hash htpasswd (substituindo $ por $$ para o docker compose ler corretamente)
            TRAEFIK_BASIC_AUTH_VAL=$(htpasswd -nb admin "$TRAEFIK_DASH_PASS_RAW" | sed 's/\$/\$\$/g')
        else
            log_warn "htpasswd não encontrado. Usando hash padrão."
            TRAEFIK_BASIC_AUTH_VAL="admin:\$\$apr1\$\$5Uqb5YDD\$\$QuT0/wmWT/xporevFvdwm0"
        fi
    fi
}

#==============================================================================
# 3. Instalação Docker (Versão Específica)
#==============================================================================

install_docker() {
    log_step "ETAPA 2/3: INSTALANDO DOCKER (Versão Fixa: ${DOCKER_FALLBACK_VER})"

    # Remove qualquer instalação anterior (swarm, pacotes)
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        log_warn "Removendo Swarm antigo..."
        docker swarm leave --force 2>/dev/null || true
    fi

    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y $pkg 2>/dev/null || true
    done

    # 1. Configura a chave GPG do Docker
    log_info "Configurando repositório Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    # 2. Define variáveis de OS e Versão
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        REPO_URL="https://download.docker.com/linux/ubuntu"
        VERSION_STRING="$DOCKER_UBUNTU_VER"
    elif [[ "$ID" == "debian" ]]; then
        REPO_URL="https://download.docker.com/linux/debian"
        VERSION_STRING="${DOCKER_FALLBACK_VER}-1~debian.${VERSION_ID}~${VERSION_CODENAME}"
    else
        log_error "SO não suportado. Use Debian ou Ubuntu."
    fi

    # 3. Adiciona o repositório Docker
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $REPO_URL \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq

    # 4. Tenta instalar a versão exata, com fallback para latest
    DOCKER_PACKAGES="docker-ce=$VERSION_STRING docker-ce-cli=$VERSION_STRING containerd.io docker-buildx-plugin docker-compose-plugin"

    if ! apt-get install -y $DOCKER_PACKAGES; then
        log_warn "Falha ao instalar versão exata ($VERSION_STRING). Instalando a última versão estável (latest)..."
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    log_info "Docker instalado com sucesso: $(docker --version)"
}

#==============================================================================
# 4. Criação de Arquivos (Compose, .env)
#==============================================================================

prepare_files() {
    clear
    log_step "ETAPA 3/3: CONFIGURANDO STACK (Arquivos e Variáveis)"

    mkdir -p $INSTALL_DIR/traefik

    # 4.1. Arquivo ACME (SSL)
    log_info "Criando arquivo acme.json e ajustando permissões..."
    touch $INSTALL_DIR/traefik/acme.json
    chmod 600 $INSTALL_DIR/traefik/acme.json

    # 4.2. Arquivo .env (Secrets - reescrito com os dados mais atuais/persistidos)
    log_info "Criando/Atualizando arquivo .env..."
    cat > $INSTALL_DIR/.env <<EOF
#======================================================
# VARIAVEIS DE AMBIENTE (GERADAS EM: $(date))
# Tracking Highend Master Installer V1.0
#======================================================

# DADOS DE DOMÍNIO E SSL
BASE_DOMAIN=${BASE_DOMAIN}
DOMAIN_TRAEFIK=${DOMAIN_TRAEFIK}
DOMAIN_PORTAINER=${DOMAIN_PORTAINER}
DOMAIN_N8N=${DOMAIN_N8N}
DOMAIN_N8N_WEBHOOK=${DOMAIN_N8N_WEBHOOK}
DOMAIN_PMA=${DOMAIN_PMA}
EMAIL_SSL=${EMAIL_SSL_VAL}

# SEGREDOS E SENHAS (Persistidas/Reutilizadas para estabilidade)
POSTGRES_PASSWORD_N8N=${POSTGRES_PASSWORD_N8N_VAL}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY_VAL}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD_VAL}
MYSQL_USER_PASSWORD=${MYSQL_USER_PASSWORD_VAL}
REDIS_PASSWORD=${REDIS_PASSWORD_VAL}

# TRAEFIK BASIC AUTH (admin:senha_hash)
TRAEFIK_DASH_PASS_RAW=${TRAEFIK_DASH_PASS_RAW}
TRAEFIK_BASIC_AUTH=${TRAEFIK_BASIC_AUTH_VAL}
EOF
    log_info "Arquivo .env com variáveis atualizadas."

    # 4.3. Docker Compose (Com Queue Mode Separado e FIXES FINAIS)
    log_info "Gerando arquivo docker-compose.yml..."
    cat > $INSTALL_DIR/docker-compose.yml <<'EOF'

# Âncora de configurações do N8N para compartilhar entre editor, webhook e worker
x-n8n-shared: &n8n-shared
  image: n8nio/n8n:stable # Versão Stable para Produção (V1.0)
  restart: unless-stopped
  depends_on:
    n8n_postgres:
      condition: service_healthy
    redis_cache:
      condition: service_started
  environment:
    # Configurações de Banco de Dados PostgreSQL (Dedicado ao N8N)
    - 'DB_TYPE=postgresdb'
    - 'DB_POSTGRESDB_HOST=n8n_postgres'
    - 'DB_POSTGRESDB_PORT=5432'
    - 'DB_POSTGRESDB_DATABASE=n8n'
    - 'DB_POSTGRESDB_USER=n8n_user'
    - 'DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD_N8N}'
    # Configurações de URL e Queue Mode
    - 'WEBHOOK_URL=https://${DOMAIN_N8N_WEBHOOK}'
    - 'N8N_EDITOR_BASE_URL=https://${DOMAIN_N8N}'
    - 'EXECUTIONS_MODE=queue'
    - 'QUEUE_BULL_REDIS_HOST=redis_cache'
    - 'QUEUE_BULL_REDIS_PORT=6379'
    - 'QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}'
    # Configurações de Estabilidade e Segurança
    - 'DB_CONNECTION_MAX_RETRIES=50' # Aumenta a tolerância na inicialização do DB
    - 'N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true' # Força permissões corretas (resolve warning)
    - 'N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}' # Chave crucial para credenciais criptografadas
    - 'N8N_ENABLE_CLUSTER_MODE=true' # Habilita o modo cluster/queue
    - 'N8N_PROXY_HOPS=1'             # Configuração para Traefik
    # Outras configurações
    - 'GENERIC_TIMEZONE=America/Sao_Paulo'
    - 'NODE_FUNCTION_ALLOW_EXTERNAL=*'
    - 'N8N_AUTOSAVE_INTERVAL=60'
    - 'N8N_PERSONALIZATION_DISABLED=true'
    - 'N8N_SKIP_CREDENTIAL_TEST=false'
  networks:
    - traefik-net
  extra_hosts:
    - 'host.docker.internal:host-gateway'

services:
  # REVERSE PROXY E SSL (Traefik)
  traefik:
    image: 'traefik:latest'
    container_name: 'traefik'
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
    command:
      - --log.level=INFO
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=traefik-net
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --api.dashboard=true
      - --api.insecure=false
      # Configuração Let's Encrypt (ACME)
      - --certificatesresolvers.letsencryptresolver.acme.email=${EMAIL_SSL}
      - --certificatesresolvers.letsencryptresolver.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencryptresolver.acme.httpchallenge=true
      - --certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
      - './traefik/acme.json:/letsencrypt/acme.json' # Volume para persistência dos certificados
    networks:
      - traefik-net
    labels:
      # Roteamento do Dashboard do Traefik (protegido por Basic Auth)
      - 'traefik.enable=true'
      - 'traefik.http.routers.traefik-dashboard.rule=Host(`${DOMAIN_TRAEFIK}`)'
      - 'traefik.http.routers.traefik-dashboard.service=api@internal'
      - 'traefik.http.routers.traefik-dashboard.entrypoints=websecure'
      - 'traefik.http.routers.traefik-dashboard.tls.certresolver=letsencryptresolver'
      - 'traefik.http.routers.traefik-dashboard.middlewares=auth'
      - 'traefik.http.middlewares.auth.basicauth.users=${TRAEFIK_BASIC_AUTH}'

  # POSTGRES DEDICADO AO N8N (DB ÚNICO)
  n8n_postgres:
    image: postgres:16
    container_name: 'n8n_postgres'
    restart: unless-stopped
    environment:
      - 'POSTGRES_DB=n8n'
      - 'POSTGRES_USER=n8n_user'
      - 'POSTGRES_PASSWORD=${POSTGRES_PASSWORD_N8N}'
    ports:
      - "5432:5432" # Porta exposta para acesso externo/ferramentas de DB
    volumes:
      - 'postgres_data:/var/lib/postgresql/data'
    networks:
      - traefik-net
    healthcheck: # Garante que o N8N só inicie após o DB estar pronto
      test: ["CMD-SHELL", "pg_isready -U n8n_user -d n8n || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # REDIS (Cache e Queue para o Cluster N8N)
  redis_cache:
    image: redis:7-alpine
    container_name: 'redis_cache'
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - 'redis_data:/data'
    networks:
      - traefik-net
    deploy:
      resources:
        limits:
          memory: 128M # Limite de memória para o Redis

  # N8N EDITOR (Web Interface e Inicialização)
  n8n_editor:
    <<: *n8n-shared
    container_name: 'n8n_editor'
    command: start
    volumes:
      - n8n_data:/home/node/.n8n
    ports:
      - "5678:5678" # REQUISITO: Porta exposta no host para comunicação API direta/depuração.
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.services.n8n-editor-service.loadbalancer.server.port=5678'
      - 'traefik.http.routers.n8n.rule=Host(`${DOMAIN_N8N}`)'
      - 'traefik.http.routers.n8n.service=n8n-editor-service'
      - 'traefik.http.routers.n8n.entrypoints=websecure'
      - 'traefik.http.routers.n8n.tls.certresolver=letsencryptresolver'

  # N8N WEBHOOK (Recebimento de Webhooks Externos)
  n8n_webhook:
    <<: *n8n-shared
    container_name: 'n8n_webhook'
    command: webhook # Inicia o serviço em modo Webhook
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.services.n8n-webhook-service.loadbalancer.server.port=5678'
      - 'traefik.http.routers.n8n-webhook.rule=Host(`${DOMAIN_N8N_WEBHOOK}`)'
      - 'traefik.http.routers.n8n-webhook.service=n8n-webhook-service'
      - 'traefik.http.routers.n8n-webhook.entrypoints=websecure'
      - 'traefik.http.routers.n8n-webhook.tls.certresolver=letsencryptresolver'

  # N8N WORKER (Execução Assíncrona de Fluxos)
  n8n_worker:
    <<: *n8n-shared
    container_name: 'n8n_worker'
    command: worker --concurrency=10 # Inicia o serviço em modo Worker

  # PORTAINER (Web UI para gerenciamento do Docker)
  portainer:
    container_name: portainer
    image: portainer/portainer-ce:2.20.2
    restart: always
    environment:
      - "PORTAINER_PUBLIC_URL=https://${DOMAIN_PORTAINER}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - traefik-net
    labels:
      # Roteamento do Portainer (Acesso via Traefik)
      - 'traefik.enable=true'
      - 'traefik.http.routers.portainer.rule=Host(`${DOMAIN_PORTAINER}`)'
      - 'traefik.http.services.portainer.loadbalancer.server.port=9000'
      - 'traefik.http.routers.portainer.entrypoints=websecure'
      - 'traefik.http.routers.portainer.tls.certresolver=letsencryptresolver'

  # MYSQL (Banco de Dados de Informações - Uso Geral)
  mysql_db:
    image: mysql:8.0
    container_name: 'mysql_db'
    restart: unless-stopped
    environment:
      - 'MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}'
      - 'MYSQL_DATABASE=infoproduct'
      - 'MYSQL_USER=n8n_mysql_user'
      - 'MYSQL_PASSWORD=${MYSQL_USER_PASSWORD}'
    volumes:
      - 'mysql_data:/var/lib/mysql'
    ports:
      - "3306:3306" # Porta padrão 3306 exposta no host
    networks:
      - traefik-net

  # PHPMYADMIN (Interface para MySQL)
  phpmyadmin:
    image: phpmyadmin/phpmyadmin:latest
    container_name: 'phpmyadmin'
    restart: unless-stopped
    depends_on:
      - mysql_db
    environment:
      - 'PMA_HOST=mysql_db' # Conecta ao serviço mysql_db
      - 'MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}'
      - 'PMA_PORT=3306'
      - 'PMA_ARBITRARY=0'
    networks:
      - traefik-net
    labels:
      # Roteamento do phpMyAdmin (Acesso via Traefik)
      - 'traefik.enable=true'
      - 'traefik.http.routers.pma.rule=Host(`${DOMAIN_PMA}`)'
      - 'traefik.http.services.pma.loadbalancer.server.port=80'
      - 'traefik.http.routers.pma.entrypoints=websecure'
      - 'traefik.http.routers.pma.tls.certresolver=letsencryptresolver'

networks:
  traefik-net:
    driver: bridge
    name: traefik-net

# Definição dos Volumes Persistentes
volumes:
  portainer_data:
    name: portainer_data
  redis_data:
  postgres_data:
  n8n_data:
  mysql_data:
EOF
    log_info "Arquivo docker-compose.yml (Cluster N8N V1.0) criado."
}

#==============================================================================
# 5. Execução e Relatório Final
#==============================================================================

deploy_stack() {
    clear
    log_step "ETAPA 3/3: INICIANDO DEPLOY COM DOCKER COMPOSE"

    cd $INSTALL_DIR

    log_info "Baixando imagens necessárias (Pull)..."
    docker compose pull

    log_info "Subindo a stack (Traefik, DBs, N8N Cluster)..."
    docker compose up -d --remove-orphans

    log_info "Stack inicializada com sucesso! (N8N Queue Mode V1.0)"
}

generate_report() {
    # Coleta o IP atual do servidor
    IP=$(hostname -I | awk '{print $1}')
    REPORT_FILE="/root/CREDENCIAIS_V1.0.txt"

    # Salva o relatório de credenciais no arquivo
    cat > "$REPORT_FILE" <<EOF
=====================================================
      INSTALAÇÃO FINALIZADA - V1.0 (QUEUE MODE)
=====================================================

DATA:          $(date)
IP SERVIDOR:   ${IP}
DIRETÓRIO DA STACK: ${INSTALL_DIR}

ACESSOS WEB (SSL via Let's Encrypt - Traefik):
-----------------------------------------
Traefik Dash:  https://${DOMAIN_TRAEFIK}
   User: admin
   Pass: ${TRAEFIK_DASH_PASS_RAW}

Portainer:     https://${DOMAIN_PORTAINER} (Versão 2.20.2)
N8N Editor:    https://${DOMAIN_N8N}
N8N Webhook:   https://${DOMAIN_N8N_WEBHOOK}
phpMyAdmin:    https://${DOMAIN_PMA}

ACESSOS DIRETOS (SEM SSL, via IP e Porta):
-----------------------------------------
N8N Editor:    http://${IP}:5678 (Acesso API ou Interface)
PostgreSQL:    http://${IP}:5432
MySQL:         http://${IP}:3306

CREDENCIAIS DE BANCO DE DADOS:
-----------------------------------------
POSTGRES (n8n_postgres:5432) - DEDICADO AO N8N:
   User: n8n_user
   Pass: ${POSTGRES_PASSWORD_N8N_VAL}
   DB:   n8n

MYSQL (mysql_db:3306) - DADOS GERAIS:
   Host Port: 3306
   Root Pass: ${MYSQL_ROOT_PASSWORD_VAL}
   User:      n8n_mysql_user
   Pass:      ${MYSQL_USER_PASSWORD_VAL}
   DB Padrão: infoproduct

N8N (Cluster/Queue Mode Secrets):
-----------------------------------------
REDIS Password: ${REDIS_PASSWORD_VAL}
Encryption Key: ${N8N_ENCRYPTION_KEY_VAL}

Comandos Rápidos (Executar em ${INSTALL_DIR}):
- Para parar:    docker compose stop
- Para subir:    docker compose up -d
- Para remover:  docker compose down
=====================================================
EOF

    # Imprime a versão colorida no terminal
    clear
    log_step "DEPLOY CONCLUÍDO! (V1.0 - Lançamento Final)"

    echo -e "${MAGENTA}${BOLD}================================================================${NC}"
    echo -e "${MAGENTA}${BOLD}             RESUMO DE INSTALAÇÃO - STACK V1.0                  ${NC}"
    echo -e "${MAGENTA}${BOLD}================================================================${NC}"
    echo -e "Data/Hora:     ${GREEN}$(date)${NC}"
    echo -e "IP Servidor:   ${GREEN}${IP}${NC}"
    echo -e "Diretório Base:  ${GREEN}${INSTALL_DIR}${NC}"

    echo -e "\n${RED}${BOLD}>> AVISO IMPORTANTE (Traefik/SSL - Rate Limit)${NC}"
    echo -e "----------------------------------------------------------------"
    echo -e "Se houver erro de certificado (código 429), o Let's Encrypt pode ter"
    echo -e "aplicado um limite de taxa. Solução: Espere 7 dias ou renomeie"
    echo -e "o arquivo ${YELLOW}acme.json${NC} em ${YELLOW}${INSTALL_DIR}/traefik/${NC} e tente novos subdomínios."

    echo -e "\n${MAGENTA}${BOLD}>> ACESSOS WEB (SSL via Traefik/Let's Encrypt)${NC}"
    echo -e "----------------------------------------------------------------"
    echo -e "Traefik Dash:  ${CYAN}https://${DOMAIN_TRAEFIK}${NC}"
    echo -e "   ${YELLOW}User: admin | Pass: ${TRAEFIK_DASH_PASS_RAW}${NC}"
    echo -e "Portainer:     ${CYAN}https://${DOMAIN_PORTAINER}${NC}"
    echo -e "N8N Editor:    ${CYAN}https://${DOMAIN_N8N}${NC}"
    echo -e "N8N Webhook:   ${CYAN}https://${DOMAIN_N8N_WEBHOOK}${NC}"
    echo -e "phpMyAdmin:    ${CYAN}https://${DOMAIN_PMA}${NC}"

    echo -e "\n${MAGENTA}${BOLD}>> CREDENCIAIS DE BANCO DE DADOS E N8N SECRETS${NC}"
    echo -e "----------------------------------------------------------------"
    echo -e "POSTGRES (n8n_postgres) N8N DB:   ${YELLOW}User: n8n_user | Pass: ${POSTGRES_PASSWORD_N8N_VAL}${NC}"
    echo -e "MYSQL (mysql_db) Dados Gerais:    ${YELLOW}Root Pass: ${MYSQL_ROOT_PASSWORD_VAL}${NC}"
    echo -e "N8N Encrypt Key (CRUCIAL!):  ${YELLOW}${N8N_ENCRYPTION_KEY_VAL}\n${NC}"

    echo -e "\n${MAGENTA}${BOLD}================================================================${NC}"
    echo -e "${GREEN}As credenciais foram salvas em ${REPORT_FILE}${NC}"
}

#==============================================================================
# MAIN (Orquestração do Fluxo de Instalação)
#==============================================================================

main() {
    main_preamble

    if [ "$(id -u)" -ne 0 ]; then log_error "Execute como ROOT: sudo ./install.sh"; fi

    read # PAUSA 1: Inicia a coleta de domínios.

    # 1. Instalação de Base (limpa a tela e começa)
    install_base_deps

    # 2. Verifica portas e coleta info (INTERATIVO)
    check_ports
    collect_info

    echo -e "\n${YELLOW}${BOLD}>> ETAPA 1 CONCLUÍDA (Pré-requisitos e Configuração de Domínios). PRÓXIMA: Instalação do Docker.${NC}"
    auto_continue # PAUSA 2: Automática (3s)

    # 3. Instala Docker
    install_docker

    echo -e "\n${YELLOW}${BOLD}>> ETAPA 2 CONCLUÍDA (Docker). PRÓXIMA: Configuração da Stack e Deploy.${NC}"
    auto_continue # PAUSA 3: Automática (3s)

    # 4. Prepara arquivos e faz o deploy
    prepare_files
    deploy_stack
    generate_report
}

main