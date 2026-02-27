#!/usr/bin/env bash
set -e

on_unexpected_error() {
    local exit_code=$?
    local line_no=${BASH_LINENO[0]}
    local cmd="${BASH_COMMAND}"
    local install_dir="${INSTALL_DIR:-/opt/stack}"
    local stack_name="${STACK_NAME:-twobrain}"
    echo -e "\n\033[0;31m[✗]\033[0m Erro inesperado na linha ${line_no}: ${cmd}"
    echo -e "    Consulte o log bruto em: \033[1;37m${install_dir}/${stack_name}-installer-error.log\033[0m\n"
    {
        echo "==== $(date) ===="
        echo "line: ${line_no}"
        echo "command: ${cmd}"
        echo "exit_code: ${exit_code}"
        echo ""
    } >> "${install_dir}/${stack_name}-installer-error.log" 2>/dev/null || true
    exit "${exit_code}"
}

trap on_unexpected_error ERR

#==============================================================================
# TWOBRAIN INSTALLER V6.6.0 - "Robust & MySQL Tuned"
# Correções: crontab portável, DOMAIN_TRAEFIK, MySQL 4GB/50% RAM, cross-platform
# Estrutura: Editor + Webhook + Worker separados
#==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
NC='\033[0m'; BOLD='\033[1m'

INSTALL_DIR="/opt/stack"
STACK_NAME="twobrain"
TRAEFIK_EXTERNAL_NETWORK="traefik-net"
AUTO_PORT_CHANGES=""
TRAEFIK_SECURE_ENTRYPOINT="websecure"
TRAEFIK_CERTRESOLVER_NAME="le"

# Flags de serviços
ENABLE_MINIO=false; ENABLE_N8N=false; ENABLE_TYPEBOT=false
ENABLE_EVOLUTION=false; ENABLE_WORDPRESS=false; ENABLE_RABBIT=false
ENABLE_PGADMIN=false; ENABLE_PMA=false
NEED_POSTGRES=false; NEED_MYSQL=false; NEED_REDIS=false
PREVIOUS_INSTALL=false
# Traefik: usar proxy existente (Coolify/etc) ou próprio (80/443 ou portas alternativas)
USE_EXISTING_TRAEFIK=false
TRAEFIK_ALT_PORTS=false
SWARM_ALREADY_ACTIVE=false
INTEGRATE_WITH_EXISTING_SWARM=false
EXPOSE_DB_PORTS=true

# Perfil de portas publicadas no host (ajustado conforme modo Traefik)
TRAEFIK_HTTP_PORT=80
TRAEFIK_HTTPS_PORT=443
MYSQL_PUBLISHED_PORT=3306
POSTGRES_PUBLISHED_PORT=5432
REDIS_PUBLISHED_PORT=6379
MINIO_API_PUBLISHED_PORT=9000
MINIO_CONSOLE_PUBLISHED_PORT=9001
N8N_EDITOR_PUBLISHED_PORT=5678
N8N_WEBHOOK_PUBLISHED_PORT=5680
EVOLUTION_PUBLISHED_PORT=8082
TYPEBOT_BUILDER_PUBLISHED_PORT=3000
TYPEBOT_VIEWER_PUBLISHED_PORT=3002
WORDPRESS_PUBLISHED_PORT=8088
RABBIT_AMQP_PUBLISHED_PORT=5672
RABBIT_MGMT_PUBLISHED_PORT=15672
PGADMIN_PUBLISHED_PORT=5050
PMA_PUBLISHED_PORT=8084

print_header() {
    clear    
    echo -e "${MAGENTA}${BOLD}"
    cat << "EOF"
  ████████╗██╗  ██╗███████╗    ███████╗████████╗ █████╗  ██████╗██╗  ██╗
  ╚══██╔══╝██║  ██║██╔════╝    ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝
     ██║   ███████║█████╗      ███████╗   ██║   ███████║██║     █████╔╝ 
     ██║   ██╔══██║██╔══╝      ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ 
     ██║   ██║  ██║███████╗    ███████║   ██║   ██║  ██║╚██████╗██║  ██╗
     ╚═╝   ╚═╝  ╚═╝╚══════╝    ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝
                    > The Stack Automation <
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

run_command_with_spinner() {
    local msg="$1"
    local logfile="$2"
    shift 2
    local spin='|/-\'
    local i=0

    printf "%b%s%b %s" "$CYAN" "$msg" "$NC" "${spin:0:1}"
    "$@" >"$logfile" 2>&1 &
    local cmd_pid=$!

    while kill -0 "$cmd_pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r%b%s%b %s" "$CYAN" "$msg" "$NC" "${spin:$i:1}"
        sleep 0.2
    done

    wait "$cmd_pid"
    local rc=$?
    if [ $rc -eq 0 ]; then
        printf "\r${GREEN}[✓]${NC} %s\n" "$msg"
    else
        printf "\r${RED}[✗]${NC} %s\n" "$msg"
    fi
    return $rc
}

append_port_change() {
    local service_name="$1"
    local old_port="$2"
    local new_port="$3"
    AUTO_PORT_CHANGES="${AUTO_PORT_CHANGES}${service_name}: ${old_port} -> ${new_port}\n"
}

extract_conflict_port_from_log() {
    local logfile="$1"
    sed -n "s/.*port '\([0-9]\+\)' is already in use.*/\1/p" "$logfile" | head -n1
}

is_port_busy_on_host() {
    local port="$1"
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

is_port_busy_on_swarm() {
    local port="$1"
    local sid
    for sid in $(docker service ls -q 2>/dev/null); do
        docker service inspect "$sid" --format '{{range .Endpoint.Ports}}{{.PublishedPort}} {{end}}' 2>/dev/null
    done | tr ' ' '\n' | grep -qx "$port"
}

find_next_free_port() {
    local start_port="$1"
    local candidate=$((start_port + 1))
    while is_port_busy_on_host "$candidate" || is_port_busy_on_swarm "$candidate"; do
        candidate=$((candidate + 1))
    done
    echo "$candidate"
}

remap_port_if_conflict() {
    local conflict_port="$1"
    local new_port

    case "$conflict_port" in
        "$TRAEFIK_HTTP_PORT")
            new_port=$(find_next_free_port "$TRAEFIK_HTTP_PORT")
            append_port_change "Traefik HTTP" "$TRAEFIK_HTTP_PORT" "$new_port"
            TRAEFIK_HTTP_PORT="$new_port"
            ;;
        "$TRAEFIK_HTTPS_PORT")
            new_port=$(find_next_free_port "$TRAEFIK_HTTPS_PORT")
            append_port_change "Traefik HTTPS" "$TRAEFIK_HTTPS_PORT" "$new_port"
            TRAEFIK_HTTPS_PORT="$new_port"
            ;;
        "$MYSQL_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$MYSQL_PUBLISHED_PORT")
            append_port_change "MySQL" "$MYSQL_PUBLISHED_PORT" "$new_port"
            MYSQL_PUBLISHED_PORT="$new_port"
            ;;
        "$POSTGRES_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$POSTGRES_PUBLISHED_PORT")
            append_port_change "PostgreSQL" "$POSTGRES_PUBLISHED_PORT" "$new_port"
            POSTGRES_PUBLISHED_PORT="$new_port"
            ;;
        "$REDIS_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$REDIS_PUBLISHED_PORT")
            append_port_change "Redis" "$REDIS_PUBLISHED_PORT" "$new_port"
            REDIS_PUBLISHED_PORT="$new_port"
            ;;
        "$MINIO_API_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$MINIO_API_PUBLISHED_PORT")
            append_port_change "MinIO API" "$MINIO_API_PUBLISHED_PORT" "$new_port"
            MINIO_API_PUBLISHED_PORT="$new_port"
            ;;
        "$MINIO_CONSOLE_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$MINIO_CONSOLE_PUBLISHED_PORT")
            append_port_change "MinIO Console" "$MINIO_CONSOLE_PUBLISHED_PORT" "$new_port"
            MINIO_CONSOLE_PUBLISHED_PORT="$new_port"
            ;;
        "$N8N_EDITOR_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$N8N_EDITOR_PUBLISHED_PORT")
            append_port_change "N8N Editor" "$N8N_EDITOR_PUBLISHED_PORT" "$new_port"
            N8N_EDITOR_PUBLISHED_PORT="$new_port"
            ;;
        "$N8N_WEBHOOK_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$N8N_WEBHOOK_PUBLISHED_PORT")
            append_port_change "N8N Webhook" "$N8N_WEBHOOK_PUBLISHED_PORT" "$new_port"
            N8N_WEBHOOK_PUBLISHED_PORT="$new_port"
            ;;
        "$EVOLUTION_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$EVOLUTION_PUBLISHED_PORT")
            append_port_change "Evolution API" "$EVOLUTION_PUBLISHED_PORT" "$new_port"
            EVOLUTION_PUBLISHED_PORT="$new_port"
            ;;
        "$TYPEBOT_BUILDER_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$TYPEBOT_BUILDER_PUBLISHED_PORT")
            append_port_change "Typebot Builder" "$TYPEBOT_BUILDER_PUBLISHED_PORT" "$new_port"
            TYPEBOT_BUILDER_PUBLISHED_PORT="$new_port"
            ;;
        "$TYPEBOT_VIEWER_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$TYPEBOT_VIEWER_PUBLISHED_PORT")
            append_port_change "Typebot Viewer" "$TYPEBOT_VIEWER_PUBLISHED_PORT" "$new_port"
            TYPEBOT_VIEWER_PUBLISHED_PORT="$new_port"
            ;;
        "$WORDPRESS_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$WORDPRESS_PUBLISHED_PORT")
            append_port_change "WordPress" "$WORDPRESS_PUBLISHED_PORT" "$new_port"
            WORDPRESS_PUBLISHED_PORT="$new_port"
            ;;
        "$RABBIT_AMQP_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$RABBIT_AMQP_PUBLISHED_PORT")
            append_port_change "RabbitMQ AMQP" "$RABBIT_AMQP_PUBLISHED_PORT" "$new_port"
            RABBIT_AMQP_PUBLISHED_PORT="$new_port"
            ;;
        "$RABBIT_MGMT_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$RABBIT_MGMT_PUBLISHED_PORT")
            append_port_change "RabbitMQ Management" "$RABBIT_MGMT_PUBLISHED_PORT" "$new_port"
            RABBIT_MGMT_PUBLISHED_PORT="$new_port"
            ;;
        "$PGADMIN_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$PGADMIN_PUBLISHED_PORT")
            append_port_change "pgAdmin" "$PGADMIN_PUBLISHED_PORT" "$new_port"
            PGADMIN_PUBLISHED_PORT="$new_port"
            ;;
        "$PMA_PUBLISHED_PORT")
            new_port=$(find_next_free_port "$PMA_PUBLISHED_PORT")
            append_port_change "phpMyAdmin" "$PMA_PUBLISHED_PORT" "$new_port"
            PMA_PUBLISHED_PORT="$new_port"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# Lista redes overlay atuais: nome e subnet (para detectar overlap, sem chumbar "ingress")
list_overlay_networks() {
    for id in $(docker network ls -f driver=overlay -q 2>/dev/null); do
        name=$(docker network inspect "$id" --format '{{.Name}}' 2>/dev/null)
        sub=$(docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
        [ -n "$name" ] && echo "  $name -> ${sub:-sem subnet}"
    done
}

# Obtém IPv4 público da máquina (para DNS). Fallback: IP local.
get_public_ipv4() {
    local ip
    local urls="https://api.ipify.org https://icanhazip.com https://ifconfig.me/ip https://ipecho.net/plain"
    for url in $urls; do
        ip=$(curl -s -4 --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '\r\n')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback: IP local (hostname -I ou hostname -i)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' | head -n1)
    [ -z "$ip" ] && ip=$(hostname -i 2>/dev/null)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

load_state() {
    [ -f "$INSTALL_DIR/.env" ] && {
        log_info "Instalação anterior detectada"
        PREVIOUS_INSTALL=true
        set -a; source "$INSTALL_DIR/.env" 2>/dev/null || true; set +a
    } || log_info "Nova instalação"
    sleep 1
}

ask_stack_name() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}      NOME DA STACK DOCKER${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    echo -e "Use um nome único para evitar conflito com stacks existentes."
    echo -e "Permitido: letras minúsculas, números, hífen e underscore.\n"

    while true; do
        read -p "Nome da stack [${STACK_NAME}]: " INPUT_STACK
        INPUT_STACK=${INPUT_STACK:-$STACK_NAME}
        INPUT_STACK=$(echo "$INPUT_STACK" | tr '[:upper:]' '[:lower:]')
        if [[ "$INPUT_STACK" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            STACK_NAME="$INPUT_STACK"
            break
        fi
        log_error "Nome inválido. Exemplo: twobrain, twobrain2, minha-stack"
    done

    log_info "Stack selecionada: ${STACK_NAME}"
    sleep 1
}

choose_existing_traefik_network() {
    local selected idx default_choice detected_net
    local all_overlay=()
    local preferred=()
    local shown=()

    detected_net=""
    for svc in $(docker service ls --format '{{.Name}}' 2>/dev/null | grep -iE 'traefik|coolify|proxy' || true); do
        while IFS= read -r arg; do
            case "$arg" in
                --providers.swarm.network=*)
                    detected_net="${arg#*=}"
                    ;;
                --providers.docker.network=*)
                    detected_net="${arg#*=}"
                    ;;
            esac
            [ -n "$detected_net" ] && break
        done < <(docker service inspect "$svc" --format '{{range .Spec.TaskTemplate.ContainerSpec.Args}}{{println .}}{{end}}' 2>/dev/null || true)
        [ -n "$detected_net" ] && break
    done

    while IFS= read -r net; do
        [ -n "$net" ] && all_overlay+=("$net")
    done < <(docker network ls --format '{{.Name}} {{.Driver}} {{.Scope}}' 2>/dev/null | awk '$2=="overlay"{print $1}' || true)

    if [ -n "$detected_net" ]; then
        if docker network inspect "$detected_net" >/dev/null 2>&1; then
            TRAEFIK_EXTERNAL_NETWORK="$detected_net"
            log_info "Rede detectada automaticamente no Traefik existente: ${TRAEFIK_EXTERNAL_NETWORK}"
            return 0
        fi
    fi

    if [ ${#all_overlay[@]} -gt 0 ]; then
        for net in "${all_overlay[@]}"; do
            if echo "$net" | grep -qiE 'traefik|proxy|public|web'; then
                preferred+=("$net")
            fi
        done
    fi

    if [ ${#preferred[@]} -gt 0 ]; then
        shown=("${preferred[@]}")
    else
        shown=("${all_overlay[@]}")
    fi

    if [ ${#shown[@]} -gt 0 ]; then
        echo -e "\n${CYAN}Redes overlay detectadas para integração com proxy:${NC}"
        idx=1
        for net in "${shown[@]}"; do
            echo -e "  ${WHITE}${idx})${NC} ${net}"
            idx=$((idx + 1))
        done
        default_choice=1
        if [ -n "$detected_net" ]; then
            idx=1
            for net in "${shown[@]}"; do
                if [ "$net" = "$detected_net" ]; then
                    default_choice=$idx
                    break
                fi
                idx=$((idx + 1))
            done
        fi
        read -p "Escolha a rede para conectar [1-${#shown[@]}, padrão: ${default_choice}]: " selected
        selected=${selected:-$default_choice}
        if [[ "$selected" =~ ^[0-9]+$ ]] && [ "$selected" -ge 1 ] && [ "$selected" -le "${#shown[@]}" ]; then
            TRAEFIK_EXTERNAL_NETWORK="${shown[$((selected - 1))]}"
        else
            TRAEFIK_EXTERNAL_NETWORK="${shown[0]}"
        fi
        log_info "Rede selecionada para proxy existente: ${TRAEFIK_EXTERNAL_NETWORK}"
    else
        TRAEFIK_EXTERNAL_NETWORK="${STACK_NAME}-traefik-net"
        log_warn "Nenhuma rede overlay de proxy encontrada."
        log_info "Será criada rede dedicada para Traefik secundário: ${TRAEFIK_EXTERNAL_NETWORK}"
    fi
}

detect_existing_traefik_defaults() {
    local detected_resolver detected_entrypoint sid svc arg resolver_name entry_name
    detected_resolver=""
    detected_entrypoint=""

    # 0) Melhor fonte: args do próprio serviço Traefik existente
    for svc in $(docker service ls --format '{{.Name}}' 2>/dev/null | grep -iE 'traefik|coolify|proxy' || true); do
        while IFS= read -r arg; do
            case "$arg" in
                --certificatesresolvers.*.acme.*)
                    resolver_name=$(echo "$arg" | sed -n 's/^--certificatesresolvers\.\([^.]*\)\.acme\..*$/\1/p')
                    [ -n "$resolver_name" ] && detected_resolver="$resolver_name"
                    ;;
                --entrypoints.*.address=:443*)
                    entry_name=$(echo "$arg" | sed -n 's/^--entrypoints\.\([^.]*\)\.address=:443.*$/\1/p')
                    [ -n "$entry_name" ] && detected_entrypoint="$entry_name"
                    ;;
            esac
            [ -n "$detected_resolver" ] && [ -n "$detected_entrypoint" ] && break
        done < <(docker service inspect "$svc" --format '{{range .Spec.TaskTemplate.ContainerSpec.Args}}{{println .}}{{end}}' 2>/dev/null || true)
        [ -n "$detected_resolver" ] && [ -n "$detected_entrypoint" ] && break
    done

    # 1) Prioriza serviços de proxy/traefik
    for sid in $(docker service ls --format '{{.ID}} {{.Name}}' 2>/dev/null | awk 'tolower($2) ~ /traefik|proxy|coolify/ {print $1}' || true); do
        while IFS= read -r line; do
            key="${line%%=*}"
            val="${line#*=}"
            case "$key" in
                traefik.http.routers.*.tls.certresolver)
                    [ -n "$val" ] && detected_resolver="$val"
                    ;;
                traefik.http.routers.*.entrypoints)
                    [ -n "$val" ] && detected_entrypoint="${val%%,*}"
                    ;;
            esac
            [ -n "$detected_resolver" ] && [ -n "$detected_entrypoint" ] && break
        done < <(docker service inspect "$sid" --format '{{range $k,$v := .Spec.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' 2>/dev/null || true)
        [ -n "$detected_resolver" ] && [ -n "$detected_entrypoint" ] && break
    done

    # 2) Fallback: varre demais serviços
    for sid in $(docker service ls -q 2>/dev/null || true); do
        while IFS= read -r line; do
            key="${line%%=*}"
            val="${line#*=}"
            case "$key" in
                traefik.http.routers.*.tls.certresolver)
                    [ -n "$val" ] && [ -z "$detected_resolver" ] && detected_resolver="$val"
                    ;;
                traefik.http.routers.*.entrypoints)
                    [ -n "$val" ] && [ -z "$detected_entrypoint" ] && detected_entrypoint="${val%%,*}"
                    ;;
            esac
            [ -n "$detected_resolver" ] && [ -n "$detected_entrypoint" ] && break
        done < <(docker service inspect "$sid" --format '{{range $k,$v := .Spec.Labels}}{{printf "%s=%s\n" $k $v}}{{end}}' 2>/dev/null || true)
        [ -n "$detected_resolver" ] && [ -n "$detected_entrypoint" ] && break
    done

    [ -n "$detected_entrypoint" ] && TRAEFIK_SECURE_ENTRYPOINT="$detected_entrypoint"
    [ -n "$detected_resolver" ] && TRAEFIK_CERTRESOLVER_NAME="$detected_resolver"
    return 0
}

ask_cleanup() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}      GESTÃO DE AMBIENTE${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    if [ "$PREVIOUS_INSTALL" = true ]; then
        echo -e "${YELLOW}⚠ Instalação existente detectada${NC}\n"
        echo "1) 🔄 Reinstalar stack (zera volumes da stack)"
        echo "2) 🗑️  Limpeza total (REMOVE TUDO)"
        echo "3) ❌ Sair"
        read -p "Opção [1-3]: " OPT
        
        case $OPT in
            2)
                read -p "Digite 'APAGAR TUDO' para confirmar: " CONFIRM
                [ "$CONFIRM" == "APAGAR TUDO" ] && {
                    log_warn "Destruindo ambiente..."
                    docker stack rm "$STACK_NAME" 2>/dev/null || true
                    sleep 10
                    # Força limpeza de volumes específicos da stack (evita erro com lista vazia)
                    for vol in $(docker volume ls -q 2>/dev/null | grep "${STACK_NAME}" || true); do
                        docker volume rm "$vol" 2>/dev/null || true
                    done
                    # Remove rede da stack anterior (não remove rede compartilhada de outro proxy)
                    docker network rm "${STACK_NAME}_traefik-net" 2>/dev/null || true
                    rm -rf $INSTALL_DIR
                    docker system prune -af --volumes
                    PREVIOUS_INSTALL=false
                    log_info "Ambiente limpo"
                    sleep 2
                } || exit 0
                ;;
            3) exit 0 ;;
        esac
    else
        mkdir -p $INSTALL_DIR
    fi
}

install_base_deps() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}   INSTALANDO DEPENDÊNCIAS${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    if ! command -v docker >/dev/null; then
        log_info "Instalando Docker..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                ca-certificates curl gnupg apache2-utils openssl git whiptail lsb-release 2>/dev/null || true
        fi
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL https://get.docker.com | sh > /dev/null 2>&1 || true
        fi
        if command -v docker >/dev/null 2>&1; then
            DOCKER_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-root}")
            usermod -aG docker "$DOCKER_USER" 2>/dev/null || true
            log_info "Docker instalado"
        else
            log_error "Docker não foi instalado. Instale manualmente e execute o script novamente."
            exit 1
        fi
    fi
    
    if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
        log_info "Inicializando Docker Swarm..."
        SWARM_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' | head -n1)
        [ -z "$SWARM_ADDR" ] && SWARM_ADDR=$(hostname -i 2>/dev/null) || SWARM_ADDR="127.0.0.1"
        docker swarm init --advertise-addr "$SWARM_ADDR"
        log_info "Swarm ativo"
        SWARM_ALREADY_ACTIVE=false
    else
        SWARM_ALREADY_ACTIVE=true
    fi
}

ask_swarm_integration_mode() {
    [ "$SWARM_ALREADY_ACTIVE" != true ] && return 0
    EXISTING_SERVICES=$(docker service ls -q 2>/dev/null | wc -l | tr -d ' ' || true)
    [ "${EXISTING_SERVICES:-0}" -eq 0 ] && return 0

    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}   INTEGRAÇÃO COM SWARM EXISTENTE${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    echo -e "Swarm já ativo com ${WHITE}${EXISTING_SERVICES}${NC} serviço(s)."
    echo -e "Recomendado integrar para evitar conflitos com infra atual."
    read -p "Ativar integração com Swarm existente? [S/n]: " INTEGRATE_OPT || true
    INTEGRATE_OPT=${INTEGRATE_OPT:-S}
    if [[ "$INTEGRATE_OPT" =~ ^[Nn]$ ]]; then
        INTEGRATE_WITH_EXISTING_SWARM=false
        EXPOSE_DB_PORTS=true
    else
        INTEGRATE_WITH_EXISTING_SWARM=true
        USE_EXISTING_TRAEFIK=true
        TRAEFIK_ALT_PORTS=false
        read -p "Expor portas de banco (MySQL/Postgres/Redis) no host? [s/N]: " DB_EXPOSE_OPT || true
        if [[ "$DB_EXPOSE_OPT" =~ ^[Ss]$ ]]; then
            EXPOSE_DB_PORTS=true
        else
            EXPOSE_DB_PORTS=false
        fi
    fi
}

reset_stack_volumes() {
    log_warn "Modo instalação limpa: removendo dados antigos da stack ${STACK_NAME}..."

    if docker stack ls --format '{{.Name}}' | grep -qx "$STACK_NAME"; then
        docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            docker stack services "$STACK_NAME" >/dev/null 2>&1 || break
            sleep 1
        done
    fi

    for vol in $(docker volume ls -q --filter "label=com.docker.stack.namespace=${STACK_NAME}" 2>/dev/null); do
        docker volume rm "$vol" >/dev/null 2>&1 || true
    done

    for vol in $(docker volume ls -q 2>/dev/null | awk -v p="${STACK_NAME}_" 'index($0,p)==1 {print $0}'); do
        docker volume rm "$vol" >/dev/null 2>&1 || true
    done

    log_info "Volumes da stack ${STACK_NAME} resetados."
}

# Define portas publicadas no host para evitar conflitos quando Traefik alt estiver ativo
configure_port_profile() {
    if [ "$TRAEFIK_ALT_PORTS" = true ]; then
        TRAEFIK_HTTP_PORT=8081
        TRAEFIK_HTTPS_PORT=8444
        MYSQL_PUBLISHED_PORT=3307
        POSTGRES_PUBLISHED_PORT=5433
        REDIS_PUBLISHED_PORT=6380
        MINIO_API_PUBLISHED_PORT=9002
        MINIO_CONSOLE_PUBLISHED_PORT=9003
        N8N_EDITOR_PUBLISHED_PORT=5679
        N8N_WEBHOOK_PUBLISHED_PORT=5681
        EVOLUTION_PUBLISHED_PORT=8083
        TYPEBOT_BUILDER_PUBLISHED_PORT=3001
        TYPEBOT_VIEWER_PUBLISHED_PORT=3003
        WORDPRESS_PUBLISHED_PORT=8089
        RABBIT_AMQP_PUBLISHED_PORT=5673
        RABBIT_MGMT_PUBLISHED_PORT=15673
        PGADMIN_PUBLISHED_PORT=5051
        PMA_PUBLISHED_PORT=8085
    else
        TRAEFIK_HTTP_PORT=80
        TRAEFIK_HTTPS_PORT=443
        MYSQL_PUBLISHED_PORT=3306
        POSTGRES_PUBLISHED_PORT=5432
        REDIS_PUBLISHED_PORT=6379
        MINIO_API_PUBLISHED_PORT=9000
        MINIO_CONSOLE_PUBLISHED_PORT=9001
        N8N_EDITOR_PUBLISHED_PORT=5678
        N8N_WEBHOOK_PUBLISHED_PORT=5680
        EVOLUTION_PUBLISHED_PORT=8082
        TYPEBOT_BUILDER_PUBLISHED_PORT=3000
        TYPEBOT_VIEWER_PUBLISHED_PORT=3002
        WORDPRESS_PUBLISHED_PORT=8088
        RABBIT_AMQP_PUBLISHED_PORT=5672
        RABBIT_MGMT_PUBLISHED_PORT=15672
        PGADMIN_PUBLISHED_PORT=5050
        PMA_PUBLISHED_PORT=8084
    fi
}

add_port_item() {
    local port=$1
    local label=$2
    PORT_ITEMS+=("${port}:${label}")
}

build_port_items() {
    PORT_ITEMS=()
    add_port_item 22 "SSH"
    add_port_item "$TRAEFIK_HTTP_PORT" "Traefik HTTP"
    add_port_item "$TRAEFIK_HTTPS_PORT" "Traefik HTTPS"
    [ "$EXPOSE_DB_PORTS" = true ] && [ "$NEED_MYSQL" = true ] && add_port_item "$MYSQL_PUBLISHED_PORT" "MySQL"
    [ "$EXPOSE_DB_PORTS" = true ] && [ "$NEED_POSTGRES" = true ] && add_port_item "$POSTGRES_PUBLISHED_PORT" "PostgreSQL"
    [ "$EXPOSE_DB_PORTS" = true ] && [ "$NEED_REDIS" = true ] && add_port_item "$REDIS_PUBLISHED_PORT" "Redis"
    [ "$ENABLE_MINIO" = true ] && { add_port_item "$MINIO_API_PUBLISHED_PORT" "MinIO API"; add_port_item "$MINIO_CONSOLE_PUBLISHED_PORT" "MinIO Console"; }
    [ "$ENABLE_N8N" = true ] && { add_port_item "$N8N_EDITOR_PUBLISHED_PORT" "N8N Editor"; add_port_item "$N8N_WEBHOOK_PUBLISHED_PORT" "N8N Webhook"; }
    [ "$ENABLE_EVOLUTION" = true ] && add_port_item "$EVOLUTION_PUBLISHED_PORT" "Evolution API"
    [ "$ENABLE_TYPEBOT" = true ] && { add_port_item "$TYPEBOT_BUILDER_PUBLISHED_PORT" "Typebot Builder"; add_port_item "$TYPEBOT_VIEWER_PUBLISHED_PORT" "Typebot Viewer"; }
    [ "$ENABLE_WORDPRESS" = true ] && add_port_item "$WORDPRESS_PUBLISHED_PORT" "WordPress"
    [ "$ENABLE_RABBIT" = true ] && { add_port_item "$RABBIT_AMQP_PUBLISHED_PORT" "RabbitMQ AMQP"; add_port_item "$RABBIT_MGMT_PUBLISHED_PORT" "RabbitMQ Management"; }
    [ "$ENABLE_PGADMIN" = true ] && add_port_item "$PGADMIN_PUBLISHED_PORT" "pgAdmin"
    [ "$ENABLE_PMA" = true ] && add_port_item "$PMA_PUBLISHED_PORT" "phpMyAdmin"
}

# Libera portas no firewall conforme modo Traefik e serviços habilitados
open_firewall_ports() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}   FIREWALL (portas necessárias)${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    build_port_items
    for item in "${PORT_ITEMS[@]}"; do
        port="${item%%:*}"
        label="${item#*:}"
        echo -e "  ${WHITE}${port}${NC} ${label}"
    done
    echo ""
    
    if command -v ufw >/dev/null 2>&1; then
        log_info "Configurando UFW..."
        for item in "${PORT_ITEMS[@]}"; do
            port="${item%%:*}"
            label="${item#*:}"
            ufw allow "${port}/tcp" comment "${label}" 2>/dev/null || true
        done
        ufw --force enable 2>/dev/null || true
        ufw reload 2>/dev/null || true
        log_info "UFW atualizado com as portas necessárias"
    elif command -v firewall-cmd >/dev/null 2>&1 && [ -r /run/firewalld ]; then
        log_info "Configurando firewalld..."
        firewall-cmd -q --permanent --add-service=ssh 2>/dev/null || true
        for item in "${PORT_ITEMS[@]}"; do
            port="${item%%:*}"
            firewall-cmd -q --permanent --add-port="${port}/tcp" 2>/dev/null || true
        done
        firewall-cmd -q --reload 2>/dev/null || true
        log_info "firewalld atualizado com as portas necessárias"
    else
        log_warn "Nenhum firewall (ufw/firewalld) detectado."
        echo -e "  ${YELLOW}No painel da VPS/cloud, libere:${NC}"
        PORTS_CSV=""
        for item in "${PORT_ITEMS[@]}"; do
            port="${item%%:*}"
            PORTS_CSV="${PORTS_CSV:+${PORTS_CSV}, }${port}"
        done
        echo -e "  ${WHITE}TCP ${PORTS_CSV}${NC}\n"
    fi
    sleep 1
}

# Detecta se já existe Traefik/Coolify e pergunta: usar existente ou Traefik próprio (80/443 ou portas alt)
ask_traefik_mode() {
    if [ "$INTEGRATE_WITH_EXISTING_SWARM" = true ]; then
        print_header
        echo -e "${CYAN}══════════════════════════════════${NC}"
        echo -e "${CYAN}   PROXY REVERSO (Traefik)${NC}"
        echo -e "${CYAN}══════════════════════════════════${NC}\n"
        detect_existing_traefik_defaults
        choose_existing_traefik_network
        log_info "Modo integração: usando proxy/rede do Swarm existente."
        sleep 1
        return 0
    fi
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}   PROXY REVERSO (Traefik)${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    DETECTED=""
    docker service ls --format '{{.Name}}' 2>/dev/null | grep -qiE 'traefik|coolify|proxy' && DETECTED="serviço"
    [ -z "$DETECTED" ] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qiE 'traefik|coolify|proxy' && DETECTED="container"
    if [ -n "$DETECTED" ]; then
        echo -e "${YELLOW}Possível Traefik/Coolify detectado neste servidor.${NC}"
        echo -e "  (e) Usar proxy existente – stack sem Traefik, conecta na rede detectada"
        echo -e "  (s) Segundo Traefik em portas 8081/8444 – evita conflito com 80/443"
        echo -e "  (p) Traefik próprio em 80/443 – ignora o existente (pode conflitar)"
        read -p "  Escolha [e/s/p, padrão: e]: " TRAEFIK_CHOICE
        TRAEFIK_CHOICE=${TRAEFIK_CHOICE:-e}
        case "$TRAEFIK_CHOICE" in
            [eE]) USE_EXISTING_TRAEFIK=true;  TRAEFIK_ALT_PORTS=false ;;
            [sS]) USE_EXISTING_TRAEFIK=false; TRAEFIK_ALT_PORTS=true ;;
            *)    USE_EXISTING_TRAEFIK=false; TRAEFIK_ALT_PORTS=false ;;
        esac
    else
        echo -e "  (n) Traefik próprio em 80/443 (padrão)"
        echo -e "  (s) Traefik em portas 8081/8444 (se 80/443 já estiverem em uso)"
        read -p "  Já existe Traefik/Coolify aqui? [n/s, padrão: n]: " TRAEFIK_CHOICE
        TRAEFIK_CHOICE=${TRAEFIK_CHOICE:-n}
        if [[ "$TRAEFIK_CHOICE" =~ ^[sS]$ ]]; then
            USE_EXISTING_TRAEFIK=false
            TRAEFIK_ALT_PORTS=true
        else
            USE_EXISTING_TRAEFIK=false
            TRAEFIK_ALT_PORTS=false
        fi
    fi
    
    if [ "$USE_EXISTING_TRAEFIK" = true ]; then
        detect_existing_traefik_defaults
        choose_existing_traefik_network
        log_info "Modo: usar proxy existente (Coolify/Traefik). Stack sem serviço Traefik."
    elif [ "$TRAEFIK_ALT_PORTS" = true ]; then
        TRAEFIK_EXTERNAL_NETWORK="${STACK_NAME}_traefik-net"
        log_info "Modo: Traefik em portas 8081 (HTTP) e 8444 (HTTPS)."
    else
        TRAEFIK_EXTERNAL_NETWORK="${STACK_NAME}_traefik-net"
        log_info "Modo: Traefik próprio em 80/443."
    fi
    sleep 1
}

selection_menu() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}   SELEÇÃO DE SERVIÇOS${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    echo -e "${GREEN}✓ Traefik${NC} - Proxy reverso SSL ${BOLD}(obrigatório)${NC}"
    echo -e "${GREEN}✓ Portainer${NC} - Interface de gerenciamento ${BOLD}(obrigatório)${NC}"
    echo -e "${GREEN}✓ Docker Swarm${NC} - Orquestração ${BOLD}(obrigatório)${NC}\n"
    
    echo -e "${YELLOW}Selecione os serviços opcionais:${NC}\n"
    
    toggle_service() {
        local NUM=$1 NAME=$2 DESC=$3 VAR=$4 CURRENT=$5
        local STATUS="${RED}[ ]${NC}"
        [ "$CURRENT" = true ] && STATUS="${GREEN}[X]${NC}"
        
        echo -e "$STATUS $NUM) ${WHITE}$NAME${NC} - $DESC"
    }
    
    while true; do
        clear
        print_header
        echo -e "${CYAN}══════════════════════════════════${NC}"
        echo -e "${CYAN}   SERVIÇOS OPCIONAIS${NC}"
        echo -e "${CYAN}══════════════════════════════════${NC}\n"
        
        toggle_service 1 "MinIO" "S3 Storage" "ENABLE_MINIO" "$ENABLE_MINIO"
        toggle_service 2 "N8N" "Automação (Editor+Webhook+Worker)" "ENABLE_N8N" "$ENABLE_N8N"
        toggle_service 3 "Typebot" "Chatbot Builder" "ENABLE_TYPEBOT" "$ENABLE_TYPEBOT"
        toggle_service 4 "Evolution" "API WhatsApp" "ENABLE_EVOLUTION" "$ENABLE_EVOLUTION"
        toggle_service 5 "WordPress" "CMS & Sites" "ENABLE_WORDPRESS" "$ENABLE_WORDPRESS"
        toggle_service 6 "RabbitMQ" "Message Broker" "ENABLE_RABBIT" "$ENABLE_RABBIT"
        toggle_service 7 "pgAdmin" "PostgreSQL GUI" "ENABLE_PGADMIN" "$ENABLE_PGADMIN"
        toggle_service 8 "phpMyAdmin" "MySQL GUI" "ENABLE_PMA" "$ENABLE_PMA"
        
        echo -e "\n${WHITE}0) Continuar com a instalação${NC}"
        echo -e "${RED}9) Sair${NC}\n"
        
        read -p "Digite o número para ativar/desativar [0-9]: " OPT
        
        case $OPT in
            1) [ "$ENABLE_MINIO" = true ] && ENABLE_MINIO=false || ENABLE_MINIO=true ;;
            2) [ "$ENABLE_N8N" = true ] && ENABLE_N8N=false || ENABLE_N8N=true ;;
            3) [ "$ENABLE_TYPEBOT" = true ] && ENABLE_TYPEBOT=false || ENABLE_TYPEBOT=true ;;
            4) [ "$ENABLE_EVOLUTION" = true ] && ENABLE_EVOLUTION=false || ENABLE_EVOLUTION=true ;;
            5) [ "$ENABLE_WORDPRESS" = true ] && ENABLE_WORDPRESS=false || ENABLE_WORDPRESS=true ;;
            6) [ "$ENABLE_RABBIT" = true ] && ENABLE_RABBIT=false || ENABLE_RABBIT=true ;;
            7) [ "$ENABLE_PGADMIN" = true ] && ENABLE_PGADMIN=false || ENABLE_PGADMIN=true ;;
            8) [ "$ENABLE_PMA" = true ] && ENABLE_PMA=false || ENABLE_PMA=true ;;
            0) break ;;
            9) exit 0 ;;
        esac
    done
    
    # Determinar dependências
    NEED_POSTGRES=false; NEED_MYSQL=false; NEED_REDIS=false
    ([ "$ENABLE_N8N" = true ] || [ "$ENABLE_TYPEBOT" = true ] || [ "$ENABLE_EVOLUTION" = true ] || [ "$ENABLE_PGADMIN" = true ]) && NEED_POSTGRES=true
    ([ "$ENABLE_N8N" = true ] || [ "$ENABLE_TYPEBOT" = true ] || [ "$ENABLE_EVOLUTION" = true ]) && NEED_REDIS=true
    ([ "$ENABLE_WORDPRESS" = true ] || [ "$ENABLE_PMA" = true ]) && NEED_MYSQL=true
}

collect_info() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}   CONFIGURAÇÃO DE DOMÍNIOS${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    [ -z "$BASE_DOMAIN" ] && {
        while true; do
            read -p "🌐 Domínio base (ex: twobrain.com.br): " BASE_DOMAIN
            [[ "$BASE_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]] && break
            echo -e "${RED}✗ Formato inválido. Use: empresa.com.br${NC}"
        done
    }
    
    echo -e "\n${GREEN}✓ Domínio base: ${WHITE}${BASE_DOMAIN}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    echo -e "${CYAN}📝 CONFIGURAÇÃO DE SUBDOMÍNIOS${NC}"
    echo -e "${WHITE}Pressione ENTER para usar o padrão.${NC}\n"
    
    echo -e "${CYAN}Portainer (obrigatório):${NC}"
    read -p "  [padrão: portainer]: " SUB
    SUB=${SUB:-portainer}
    DOMAIN_PORTAINER="${SUB}.${BASE_DOMAIN}"
    echo -e "  ${GREEN}→${NC} ${WHITE}${DOMAIN_PORTAINER}${NC}\n"
    
    echo -e "${CYAN}Traefik Dashboard:${NC}"
    read -p "  [padrão: traefik]: " SUB
    SUB=${SUB:-traefik}
    DOMAIN_TRAEFIK="${SUB}.${BASE_DOMAIN}"
    echo -e "  ${GREEN}→${NC} ${WHITE}${DOMAIN_TRAEFIK}${NC}\n"
    
    [ "$ENABLE_MINIO" = true ] && {
        echo -e "${CYAN}MinIO Storage:${NC}"
        read -p "  Console [padrão: minio]: " SUB; SUB=${SUB:-minio}
        DOMAIN_MINIO_CONSOLE="${SUB}.${BASE_DOMAIN}"
        read -p "  API S3 [padrão: s3]: " SUB; SUB=${SUB:-s3}
        DOMAIN_MINIO_API="${SUB}.${BASE_DOMAIN}"
    }
    
    [ "$ENABLE_N8N" = true ] && {
        echo -e "${CYAN}N8N Automation:${NC}"
        read -p "  Editor [padrão: n8n]: " SUB; SUB=${SUB:-n8n}
        DOMAIN_N8N="${SUB}.${BASE_DOMAIN}"
        read -p "  Webhook [padrão: webhook]: " SUB; SUB=${SUB:-webhook}
        DOMAIN_N8N_WEBHOOK="${SUB}.${BASE_DOMAIN}"
        echo -e "  ${GREEN}→${NC} ${WHITE}${DOMAIN_N8N}${NC}"
        echo -e "  ${GREEN}→${NC} ${WHITE}${DOMAIN_N8N_WEBHOOK}${NC}\n"
    }
    
    [ "$ENABLE_TYPEBOT" = true ] && {
        echo -e "${CYAN}Typebot:${NC}"
        read -p "  Builder [padrão: typebot]: " SUB; SUB=${SUB:-typebot}
        DOMAIN_TYPEBOT="${SUB}.${BASE_DOMAIN}"
        read -p "  Viewer [padrão: bot]: " SUB; SUB=${SUB:-bot}
        DOMAIN_TYPEBOT_VIEWER="${SUB}.${BASE_DOMAIN}"
    }
    
    [ "$ENABLE_EVOLUTION" = true ] && {
        echo -e "${CYAN}Evolution API:${NC}"
        read -p "  [padrão: evolution]: " SUB; SUB=${SUB:-evolution}
        DOMAIN_EVOLUTION="${SUB}.${BASE_DOMAIN}"
    }
    
    [ "$ENABLE_WORDPRESS" = true ] && {
        echo -e "${CYAN}WordPress:${NC}"
        read -p "  [padrão: wordpress]: " SUB; SUB=${SUB:-wordpress}
        DOMAIN_WORDPRESS="${SUB}.${BASE_DOMAIN}"
    }
    
    [ "$ENABLE_RABBIT" = true ] && {
        echo -e "${CYAN}RabbitMQ:${NC}"
        read -p "  [padrão: rabbit]: " SUB; SUB=${SUB:-rabbit}
        DOMAIN_RABBIT="${SUB}.${BASE_DOMAIN}"
    }
    
    [ "$ENABLE_PGADMIN" = true ] && {
        echo -e "${CYAN}pgAdmin:${NC}"
        read -p "  [padrão: pgadmin]: " SUB; SUB=${SUB:-pgadmin}
        DOMAIN_PGADMIN="${SUB}.${BASE_DOMAIN}"
    }
    
    [ "$ENABLE_PMA" = true ] && {
        echo -e "${CYAN}phpMyAdmin:${NC}"
        read -p "  [padrão: pma]: " SUB; SUB=${SUB:-pma}
        DOMAIN_PMA="${SUB}.${BASE_DOMAIN}"
    }
    
    EMAIL_SSL=${EMAIL_SSL:-"admin@${BASE_DOMAIN}"}
    read -p "Email SSL [$EMAIL_SSL]: " i; EMAIL_SSL=${i:-$EMAIL_SSL}
    
    if [ "$ENABLE_TYPEBOT" = true ] || [ "$ENABLE_N8N" = true ] || [ "$ENABLE_WORDPRESS" = true ]; then
        read -p "Configurar SMTP real? [s/N]: " s
        [[ $s =~ ^[Ss]$ ]] && {
            read -p "SMTP Host: " SMTP_HOST
            read -p "SMTP Port [587]: " SMTP_PORT; SMTP_PORT=${SMTP_PORT:-587}
            read -p "SMTP User: " SMTP_USER
            read -sp "SMTP Pass: " SMTP_PASS; echo
            read -p "SMTP From [$EMAIL_SSL]: " SMTP_FROM; SMTP_FROM=${SMTP_FROM:-$EMAIL_SSL}
        } || {
            SMTP_HOST="smtp.fake.com"; SMTP_PORT="587"
            SMTP_USER="fake"; SMTP_PASS="fake"; SMTP_FROM="$EMAIL_SSL"
        }
    fi
    
    log_info "Gerando senhas (se não existirem)..."
    [ -z "$TRAEFIK_PASS" ] && TRAEFIK_PASS=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
    TRAEFIK_AUTH=$(htpasswd -nbB admin "$TRAEFIK_PASS" | sed 's/\$/\$\$/g')
    [ -z "$PG_PASS_N8N" ] && PG_PASS_N8N=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    [ -z "$PG_PASS_EVO" ] && PG_PASS_EVO=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    [ -z "$PG_PASS_TYPEBOT" ] && PG_PASS_TYPEBOT=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    [ -z "$MYSQL_ROOT_PASS" ] && MYSQL_ROOT_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    [ -z "$WP_DB_PASS" ] && WP_DB_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    [ -z "$REDIS_PASS" ] && REDIS_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    [ -z "$N8N_KEY" ] && N8N_KEY=$(openssl rand -base64 24)
    [ -z "$EVO_API_KEY" ] && EVO_API_KEY=$(openssl rand -hex 32)
    [ -z "$TYPEBOT_ENC_KEY" ] && TYPEBOT_ENC_KEY=$(openssl rand -base64 24)
    [ -z "$RABBIT_PASS" ] && RABBIT_PASS=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
    [ -z "$PGADMIN_PASS" ] && PGADMIN_PASS=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
    [ -z "$MINIO_ROOT_PASSWORD" ] && MINIO_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    MINIO_ROOT_USER="admin"
    
    # MySQL InnoDB buffer: automático 50% ou valor definido (só se MySQL habilitado)
    if [ "$NEED_MYSQL" = true ]; then
        if [ -r /proc/meminfo ]; then
            TOTAL_RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
            RAM_MB=$((TOTAL_RAM_KB / 1024))
            AUTO_MB=$((RAM_MB / 2))
            [ "${AUTO_MB:-0}" -lt 4096 ] && AUTO_MB=4096
        else
            RAM_MB=8192
            AUTO_MB=4096
        fi
        echo -e "\n${CYAN}MySQL InnoDB buffer (RAM para tabelas/cache)${NC}"
        echo -e "  RAM da máquina: ${WHITE}$((RAM_MB / 1024)) GB${NC} (50% = ${WHITE}$((AUTO_MB / 1024)) GB${NC})"
        echo -e "  (a) Automático 50% da RAM  (d) Valor definido"
        read -p "  Escolha [a/d, padrão: a]: " MYSQL_RAM_OPT
        MYSQL_RAM_OPT=${MYSQL_RAM_OPT:-a}
        if [[ "$MYSQL_RAM_OPT" =~ ^[Dd]$ ]]; then
            # Opções pré-definidas compatíveis com a máquina (até 50%)
            PREDEF="512 1024 2048 4096 8192 16384 32768"
            MAX_MB=$AUTO_MB
            [ "$RAM_MB" -lt "$MAX_MB" ] && MAX_MB=$RAM_MB
            OPTIONS=""
            for mb in $PREDEF; do
                [ "$mb" -le "$MAX_MB" ] && OPTIONS="${OPTIONS:+$OPTIONS }$mb"
            done
            echo -e "  Opções compatíveis (até 50% = ${AUTO_MB}MB):"
            i=1
            for mb in $OPTIONS; do
                [ -z "$mb" ] && continue
                if [ "$mb" -ge 1024 ]; then
                    label="$((mb/1024))G"
                else
                    label="${mb}M"
                fi
                echo -e "    ${i}) ${label} (${mb}MB)"
                i=$((i+1))
            done
            echo -e "    0) Digitar valor em MB"
            read -p "  Número ou MB [padrão: 4096]: " choice
            choice=${choice:-4096}
            if [ "$choice" = "0" ]; then
                read -p "  Valor em MB: " MYSQL_BUFFER_MB
                MYSQL_BUFFER_MB=${MYSQL_BUFFER_MB:-4096}
            else
                n=1
                for mb in $OPTIONS; do
                    [ -z "$mb" ] && continue
                    if [ "$n" = "$choice" ]; then
                        MYSQL_BUFFER_MB=$mb
                        break
                    fi
                    n=$((n+1))
                done
                if [ -z "$MYSQL_BUFFER_MB" ]; then
                    MYSQL_BUFFER_MB=$choice
                fi
            fi
            MYSQL_BUFFER_MB=${MYSQL_BUFFER_MB:-4096}
        else
            MYSQL_BUFFER_MB=$AUTO_MB
        fi
        MYSQL_INNODB_BUFFER_POOL_SIZE="${MYSQL_BUFFER_MB}M"
    fi
}

generate_files() {
    print_header
    log_info "Gerando configurações..."
    
    # Garantir que variáveis de domínio estão definidas (evita Host(``) no Traefik)
    if [ -z "$BASE_DOMAIN" ] || [ -z "$DOMAIN_PORTAINER" ]; then
        log_error "Variáveis de domínio vazias (BASE_DOMAIN/DOMAIN_PORTAINER). Execute a instalação novamente e informe os domínios."
        exit 1
    fi
    
    mkdir -p $INSTALL_DIR/traefik
    touch $INSTALL_DIR/traefik/acme.json && chmod 600 $INSTALL_DIR/traefik/acme.json
    
    [ "$NEED_MYSQL" = true ] && {
        mkdir -p "$INSTALL_DIR/mysql/conf.d"
        cat > "$INSTALL_DIR/mysql/conf.d/custom.cnf" <<MYSQLCNF
[mysqld]
innodb_buffer_pool_size=$MYSQL_INNODB_BUFFER_POOL_SIZE
innodb_log_file_size=256M
innodb_flush_log_at_trx_commit=2
max_connections=200
# Padrão brasileiro: charset, collation e fuso horário
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-time-zone='-03:00'
lc_time_names=pt_BR

[client]
default-character-set=utf8mb4
MYSQLCNF
        log_info "MySQL config: buffer pool ${MYSQL_INNODB_BUFFER_POOL_SIZE}, locale BR (utf8mb4, America/Sao_Paulo)"
    }
    
    cat > $INSTALL_DIR/.env <<EOF
BASE_DOMAIN=$BASE_DOMAIN
EMAIL_SSL=$EMAIL_SSL
TRAEFIK_PASS=$TRAEFIK_PASS
TRAEFIK_AUTH=$TRAEFIK_AUTH
DOMAIN_TRAEFIK=$DOMAIN_TRAEFIK
DOMAIN_PORTAINER=$DOMAIN_PORTAINER
DOMAIN_MINIO_CONSOLE=$DOMAIN_MINIO_CONSOLE
DOMAIN_MINIO_API=$DOMAIN_MINIO_API
DOMAIN_N8N=$DOMAIN_N8N
DOMAIN_N8N_WEBHOOK=$DOMAIN_N8N_WEBHOOK
DOMAIN_EVOLUTION=$DOMAIN_EVOLUTION
DOMAIN_TYPEBOT=$DOMAIN_TYPEBOT
DOMAIN_TYPEBOT_VIEWER=$DOMAIN_TYPEBOT_VIEWER
DOMAIN_RABBIT=$DOMAIN_RABBIT
DOMAIN_PGADMIN=$DOMAIN_PGADMIN
DOMAIN_WORDPRESS=$DOMAIN_WORDPRESS
DOMAIN_PMA=$DOMAIN_PMA
STACK_NAME=$STACK_NAME
TRAEFIK_EXTERNAL_NETWORK=$TRAEFIK_EXTERNAL_NETWORK
TRAEFIK_SECURE_ENTRYPOINT=$TRAEFIK_SECURE_ENTRYPOINT
TRAEFIK_CERTRESOLVER_NAME=$TRAEFIK_CERTRESOLVER_NAME
INTEGRATE_WITH_EXISTING_SWARM=$INTEGRATE_WITH_EXISTING_SWARM
EXPOSE_DB_PORTS=$EXPOSE_DB_PORTS
TRAEFIK_HTTP_PORT=$TRAEFIK_HTTP_PORT
TRAEFIK_HTTPS_PORT=$TRAEFIK_HTTPS_PORT
MYSQL_PUBLISHED_PORT=$MYSQL_PUBLISHED_PORT
POSTGRES_PUBLISHED_PORT=$POSTGRES_PUBLISHED_PORT
REDIS_PUBLISHED_PORT=$REDIS_PUBLISHED_PORT
MINIO_API_PUBLISHED_PORT=$MINIO_API_PUBLISHED_PORT
MINIO_CONSOLE_PUBLISHED_PORT=$MINIO_CONSOLE_PUBLISHED_PORT
N8N_EDITOR_PUBLISHED_PORT=$N8N_EDITOR_PUBLISHED_PORT
N8N_WEBHOOK_PUBLISHED_PORT=$N8N_WEBHOOK_PUBLISHED_PORT
EVOLUTION_PUBLISHED_PORT=$EVOLUTION_PUBLISHED_PORT
TYPEBOT_BUILDER_PUBLISHED_PORT=$TYPEBOT_BUILDER_PUBLISHED_PORT
TYPEBOT_VIEWER_PUBLISHED_PORT=$TYPEBOT_VIEWER_PUBLISHED_PORT
WORDPRESS_PUBLISHED_PORT=$WORDPRESS_PUBLISHED_PORT
RABBIT_AMQP_PUBLISHED_PORT=$RABBIT_AMQP_PUBLISHED_PORT
RABBIT_MGMT_PUBLISHED_PORT=$RABBIT_MGMT_PUBLISHED_PORT
PGADMIN_PUBLISHED_PORT=$PGADMIN_PUBLISHED_PORT
PMA_PUBLISHED_PORT=$PMA_PUBLISHED_PORT
PG_PASS_N8N=$PG_PASS_N8N
PG_PASS_EVO=$PG_PASS_EVO
PG_PASS_TYPEBOT=$PG_PASS_TYPEBOT
MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS
WP_DB_PASS=$WP_DB_PASS
REDIS_PASSWORD=$REDIS_PASS
N8N_ENCRYPTION_KEY=$N8N_KEY
EVOLUTION_API_KEY=$EVO_API_KEY
TYPEBOT_ENC_KEY=$TYPEBOT_ENC_KEY
RABBIT_PASS=$RABBIT_PASS
PGADMIN_PASS=$PGADMIN_PASS
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
SMTP_FROM=$SMTP_FROM
ENABLE_MINIO=$ENABLE_MINIO
ENABLE_N8N=$ENABLE_N8N
ENABLE_TYPEBOT=$ENABLE_TYPEBOT
ENABLE_EVOLUTION=$ENABLE_EVOLUTION
ENABLE_WORDPRESS=$ENABLE_WORDPRESS
ENABLE_RABBIT=$ENABLE_RABBIT
ENABLE_PGADMIN=$ENABLE_PGADMIN
ENABLE_PMA=$ENABLE_PMA
USE_EXISTING_TRAEFIK=$USE_EXISTING_TRAEFIK
TRAEFIK_ALT_PORTS=$TRAEFIK_ALT_PORTS
EOF

    generate_compose
    write_cloudflare_tutorial
}

# Tutorial: Cloudflare e portas (gravado em $INSTALL_DIR para o cliente)
write_cloudflare_tutorial() {
    TUT="$INSTALL_DIR/CLOUDFLARE-E-PORTAS.txt"
    cat > "$TUT" <<'TUTORIAL_EOF'
═══════════════════════════════════════════════════════════════
  TUTORIAL: CLOUDFLARE E PORTAS (TWOBRAIN)
═══════════════════════════════════════════════════════════════

1. PORTAS A LIBERAR NO PAINEL DA VPS/CLOUD
────────────────────────────────────────────
No firewall do provedor (Security Groups, Firewall, Network):

  TCP 22    – SSH (acesso ao servidor)
  TCP (demais portas exibidas no passo de firewall do instalador)
             (a lista muda conforme serviços habilitados e modo Traefik)

Sem as portas de publicação liberadas, o Traefik não recebe tráfego
e você não consegue acessar nem autenticar.

2. CLOUDFLARE – O QUE CONFIGURAR
────────────────────────────────────────────
• SSL/TLS:
  – Modo: Full ou Full (strict)
  – Full (strict) exige certificado válido na origem (Let's Encrypt).

• Proxy (ícone ao lado do registro DNS):
  – Laranja (Proxied) = tráfego passa pelo Cloudflare (recomendado).
  – Cinza (DNS only) = DNS aponta direto para o IP; SSL na origem.

• Se usar Traefik em portas alternativas:
  – No Cloudflare não dá para mudar porta por registro.
  – Opção A: Proxy laranja + origem em 80/443 (Traefik padrão).
  – Opção B: Acessar direto pelo IP com a porta HTTPS alternativa.

3. REDES DOCKER (SWARM) – POSSÍVEIS PROBLEMAS
────────────────────────────────────────────
• "Pool overlaps": duas redes overlay usam a mesma faixa de IP.
  – Liste quem usa o quê: docker network ls -f driver=overlay
  – Para cada rede: docker network inspect NOME --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
  – Ou use o script: diagnose-docker-networks.sh
  – Nossa rede (<stack>_traefik-net) usa 172.25.0.0/24. Se outra rede já usar essa ou uma faixa que a inclua, pode dar overlap.

• Serviço Traefik em "Rejected":
  – Confira as portas configuradas no firewall do SO (ufw/firewalld) e do painel da VPS.
  – Confira redes: diagnose-docker-networks.sh e, se precisar, use outra subnet no compose.

4. DEPLOY MANUAL (sempre carregue o .env)
────────────────────────────────────────────
Se rodar "docker stack deploy" à mão, as variáveis de domínio vêm do .env.
Sem isso, o Traefik recebe Host(``) e dá "no domain was given".

  cd /opt/stack
  set -a && source .env && set +a
  docker stack deploy -c docker-compose.yml <nome-da-stack>

5. RESUMO RÁPIDO
────────────────────────────────────────────
• Libere no painel exatamente as portas mostradas no passo de firewall do instalador.
• Cloudflare: SSL Full ou Full (strict); proxy laranja se quiser passar pelo CF.
• Erro "no domain was given": .env sem domínios ou deploy sem source .env (veja item 4).
• Erro de rede: rode diagnose-docker-networks.sh e evite subnet em uso.
TUTORIAL_EOF
    log_info "Tutorial gravado: $TUT"
}

generate_compose() {
    # Rede: proxy existente = external; nosso Traefik = rede no compose com subnet fixa (evita overlap com outras redes overlay)
    if [ "$USE_EXISTING_TRAEFIK" = true ]; then
        cat > $INSTALL_DIR/docker-compose.yml <<NET_EXT_EOF
networks:
  traefik-net:
    external: true
    name: ${TRAEFIK_EXTERNAL_NETWORK}

NET_EXT_EOF
    else
        # Rede criada pela stack com subnet fixa (evita overlap com outras redes overlay já existentes)
        cat > $INSTALL_DIR/docker-compose.yml <<'NET_INT_EOF'
networks:
  traefik-net:
    driver: overlay
    attachable: true
    ipam:
      config:
        - subnet: 172.25.0.0/24

NET_INT_EOF
    fi

    cat >> $INSTALL_DIR/docker-compose.yml <<'COMPOSE_EOF'
volumes:
  traefik_certs:
  portainer_data:
  postgres_data:
  redis_data:
  mysql_data:
  minio_data:

services:
COMPOSE_EOF

    # Traefik: só inclui se NÃO for usar proxy existente (Coolify)
    # Portas em mode: host = abre direto no host, sem usar rede de publicação do Swarm (evita "Pool overlaps")
    if [ "$USE_EXISTING_TRAEFIK" != true ]; then
        # Rede criada pela stack = <stack>_traefik-net (nome real no Swarm)
        TRAEFIK_SWARM_NET="${STACK_NAME}_traefik-net"
        cat >> $INSTALL_DIR/docker-compose.yml <<TRAEFIK_EOF

  traefik:
    image: traefik:latest
    networks:
      - traefik-net
    ports:
      - target: 80
        published: $TRAEFIK_HTTP_PORT
        protocol: tcp
        mode: host
      - target: 443
        published: $TRAEFIK_HTTPS_PORT
        protocol: tcp
        mode: host
    command:
      - --api.dashboard=true
      - --api.insecure=false
      - --providers.docker=false
      - --providers.swarm=true
      - --providers.swarm.exposedbydefault=false
      - --providers.swarm.network=$TRAEFIK_SWARM_NET
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=\${EMAIL_SSL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --log.level=INFO
      - --accesslog=true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - './traefik/acme.json:/letsencrypt/acme.json'
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.traefik.rule=Host(`${DOMAIN_TRAEFIK}`)'
      - 'traefik.http.routers.traefik.service=api@internal'
      - 'traefik.http.routers.traefik.middlewares=auth'
      - 'traefik.http.middlewares.auth.basicauth.users=\${TRAEFIK_AUTH}' 
      - 'traefik.http.routers.traefik.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}'
      - 'traefik.http.services.dummy-svc.loadbalancer.server.port=9999'
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints: 
          - node.role == manager
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
TRAEFIK_EOF
    fi

    cat >> $INSTALL_DIR/docker-compose.yml <<'PORTAINER_EOF'

  portainer:
    image: portainer/portainer-ce:latest
    networks: 
      - traefik-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints: 
          - node.role == manager
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.portainer.rule=Host(`${DOMAIN_PORTAINER}`)
        - traefik.http.routers.portainer.service=portainer
        - traefik.http.routers.portainer.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.portainer.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.portainer.loadbalancer.server.port=9000
      restart_policy:
        condition: on-failure
PORTAINER_EOF

    [ "$NEED_POSTGRES" = true ] && {
    if [ "$EXPOSE_DB_PORTS" = true ]; then
        POSTGRES_PORTS_BLOCK=$(cat <<'EOF'
    ports:
      - target: 5432
        published: ${POSTGRES_PUBLISHED_PORT}
        protocol: tcp
        mode: host
EOF
)
    else
        POSTGRES_PORTS_BLOCK=""
    fi
    cat >> $INSTALL_DIR/docker-compose.yml <<PG_EOF

  postgres:
    image: postgres:16-alpine
    networks: 
      - traefik-net
${POSTGRES_PORTS_BLOCK}
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n_user
      POSTGRES_PASSWORD: ${PG_PASS_N8N}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    deploy:
      mode: replicated
      replicas: 1
      restart_policy:
        condition: on-failure
PG_EOF
    }

    [ "$NEED_REDIS" = true ] && {
    if [ "$EXPOSE_DB_PORTS" = true ]; then
        REDIS_PORTS_BLOCK=$(cat <<'EOF'
    ports:
      - target: 6379
        published: ${REDIS_PUBLISHED_PORT}
        protocol: tcp
        mode: host
EOF
)
    else
        REDIS_PORTS_BLOCK=""
    fi
    cat >> $INSTALL_DIR/docker-compose.yml <<REDIS_EOF

  redis:
    image: redis:7-alpine
    networks: 
      - traefik-net
${REDIS_PORTS_BLOCK}
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    deploy:
      mode: replicated
      replicas: 1
      restart_policy:
        condition: on-failure
REDIS_EOF
    }

    [ "$NEED_MYSQL" = true ] && {
    if [ "$EXPOSE_DB_PORTS" = true ]; then
        MYSQL_PORTS_BLOCK=$(cat <<'EOF'
    ports:
      - target: 3306
        published: ${MYSQL_PUBLISHED_PORT}
        protocol: tcp
        mode: host
EOF
)
    else
        MYSQL_PORTS_BLOCK=""
    fi
    cat >> $INSTALL_DIR/docker-compose.yml <<MYSQL_EOF

  mysql:
    image: mysql:8.0
    networks: 
      - traefik-net
${MYSQL_PORTS_BLOCK}
    environment:
      TZ: America/Sao_Paulo
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: ${WP_DB_PASS}
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql/conf.d/custom.cnf:/etc/mysql/conf.d/custom.cnf:ro
    deploy:
      mode: replicated
      replicas: 1
      restart_policy:
        condition: on-failure
MYSQL_EOF
    }

    [ "$ENABLE_MINIO" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'MINIO_EOF'

  minio:
    image: minio/minio:latest
    networks: 
      - traefik-net
    command: server /data --console-address ":9001"
    ports:
      - target: 9000
        published: ${MINIO_API_PUBLISHED_PORT}
        protocol: tcp
        mode: host
      - target: 9001
        published: ${MINIO_CONSOLE_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - minio_data:/data
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.minio-api.rule=Host(`${DOMAIN_MINIO_API}`)
        - traefik.http.routers.minio-api.service=minio-api
        - traefik.http.routers.minio-api.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.minio-api.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.minio-api.loadbalancer.server.port=9000
        - traefik.http.routers.minio-console.rule=Host(`${DOMAIN_MINIO_CONSOLE}`)
        - traefik.http.routers.minio-console.service=minio-console
        - traefik.http.routers.minio-console.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.minio-console.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.minio-console.loadbalancer.server.port=9001
      restart_policy:
        condition: on-failure
MINIO_EOF

    [ "$ENABLE_N8N" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'N8N_EOF'

  n8n_editor:
    image: n8nio/n8n:stable
    networks: 
      - traefik-net
    ports:
      - target: 5678
        published: ${N8N_EDITOR_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=${PG_PASS_N8N}
      - N8N_EDITOR_BASE_URL=https://${DOMAIN_N8N}
      - WEBHOOK_URL=https://${DOMAIN_N8N_WEBHOOK}
      - EXECUTIONS_MODE=queue
      - N8N_PROXY_HOPS=1
      - N8N_TRUST_PROXY=true
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_ENABLE_CLUSTER_MODE=true
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - N8N_EMAIL_MODE=smtp
      - N8N_SMTP_HOST=${SMTP_HOST}
      - N8N_SMTP_PORT=${SMTP_PORT}
      - N8N_SMTP_USER=${SMTP_USER}
      - N8N_SMTP_PASS=${SMTP_PASS}
      - N8N_SMTP_SSL=true
      - N8N_SMTP_SENDER=${SMTP_FROM}
      - N8N_COMMUNITY_PACKAGES_ENABLED=false
      - N8N_DEFAULT_BINARY_DATA_MODE=filesystem
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
      - N8N_RUNNERS_TASK_TIMEOUT=30000
      - QUEUE_WORKER_LOCK_DURATION=120000
      - QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD=20000
      - EXECUTIONS_TIMEOUT=36000
      - N8N_PAYLOAD_SIZE_MAX=256
      - NODE_OPTIONS="--max-old-space-size=4096"
    command: start
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.n8n.rule=Host(`${DOMAIN_N8N}`)
        - traefik.http.routers.n8n.service=n8n
        - traefik.http.routers.n8n.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.n8n.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.n8n.loadbalancer.server.port=5678
      restart_policy:
        condition: on-failure

  n8n_webhook:
    image: n8nio/n8n:stable
    networks: 
      - traefik-net
    ports:
      - target: 5678
        published: ${N8N_WEBHOOK_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=${PG_PASS_N8N}
      - N8N_EDITOR_BASE_URL=https://${DOMAIN_N8N}
      - WEBHOOK_URL=https://${DOMAIN_N8N_WEBHOOK}
      - EXECUTIONS_MODE=queue
      - N8N_PROXY_HOPS=1
      - N8N_TRUST_PROXY=true
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_ENABLE_CLUSTER_MODE=true
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - N8N_DEFAULT_BINARY_DATA_MODE=filesystem
      - N8N_PAYLOAD_SIZE_MAX=256
      - NODE_OPTIONS="--max-old-space-size=2048"
    command: webhook
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.n8n-webhook.rule=Host(`${DOMAIN_N8N_WEBHOOK}`)
        - traefik.http.routers.n8n-webhook.service=n8n-webhook
        - traefik.http.routers.n8n-webhook.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.n8n-webhook.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.n8n-webhook.loadbalancer.server.port=5678
      restart_policy:
        condition: on-failure

  n8n_worker:
    image: n8nio/n8n:stable
    networks: 
      - traefik-net
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=${PG_PASS_N8N}
      - N8N_EDITOR_BASE_URL=https://${DOMAIN_N8N}
      - WEBHOOK_URL=https://${DOMAIN_N8N_WEBHOOK}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_ENABLE_CLUSTER_MODE=true
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - N8N_EMAIL_MODE=smtp
      - N8N_SMTP_HOST=${SMTP_HOST}
      - N8N_SMTP_PORT=${SMTP_PORT}
      - N8N_SMTP_USER=${SMTP_USER}
      - N8N_SMTP_PASS=${SMTP_PASS}
      - N8N_SMTP_SSL=true
      - N8N_SMTP_SENDER=${SMTP_FROM}
      - N8N_COMMUNITY_PACKAGES_ENABLED=false
      - N8N_DEFAULT_BINARY_DATA_MODE=filesystem
      - N8N_RUNNERS_TASK_TIMEOUT=30000
      - QUEUE_WORKER_LOCK_DURATION=120000
      - QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD=20000
      - EXECUTIONS_TIMEOUT=3600
      - NODE_OPTIONS="--max-old-space-size=4096"
    command: worker --concurrency=10
    deploy:
      mode: replicated
      replicas: 1
      restart_policy:
        condition: on-failure
N8N_EOF

    [ "$ENABLE_EVOLUTION" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'EVO_EOF'

  evolution:
    image: evoapicloud/evolution-api:v2.3.7
    networks: 
      - traefik-net
    ports:
      - target: 8080
        published: ${EVOLUTION_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      SERVER_URL: https://${DOMAIN_EVOLUTION}
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://evolution:${PG_PASS_EVO}@postgres:5432/evolution
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://:${REDIS_PASSWORD}@redis:6379/1
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.evolution.rule=Host(`${DOMAIN_EVOLUTION}`)
        - traefik.http.routers.evolution.service=evolution
        - traefik.http.routers.evolution.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.evolution.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.evolution.loadbalancer.server.port=8080
      restart_policy:
        condition: on-failure
EVO_EOF

    [ "$ENABLE_TYPEBOT" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'TYPEBOT_EOF'

  typebot-builder:
    image: baptistearno/typebot-builder:latest
    networks: 
      - traefik-net
    ports:
      - target: 3000
        published: ${TYPEBOT_BUILDER_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      DATABASE_URL: postgresql://typebot:${PG_PASS_TYPEBOT}@postgres:5432/typebot
      NEXTAUTH_URL: https://${DOMAIN_TYPEBOT}
      NEXT_PUBLIC_VIEWER_URL: https://${DOMAIN_TYPEBOT_VIEWER}
      ENCRYPTION_SECRET: ${TYPEBOT_ENC_KEY}
      ADMIN_EMAIL: ${EMAIL_SSL}
      SMTP_HOST: ${SMTP_HOST}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_USERNAME: ${SMTP_USER}
      SMTP_PASSWORD: ${SMTP_PASS}
      NEXT_PUBLIC_SMTP_FROM: ${SMTP_FROM}
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.typebot.rule=Host(`${DOMAIN_TYPEBOT}`)
        - traefik.http.routers.typebot.service=typebot
        - traefik.http.routers.typebot.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.typebot.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.typebot.loadbalancer.server.port=3000
      restart_policy:
        condition: on-failure

  typebot-viewer:
    image: baptistearno/typebot-viewer:latest
    networks: 
      - traefik-net
    ports:
      - target: 3000
        published: ${TYPEBOT_VIEWER_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      DATABASE_URL: postgresql://typebot:${PG_PASS_TYPEBOT}@postgres:5432/typebot
      NEXT_PUBLIC_VIEWER_URL: https://${DOMAIN_TYPEBOT_VIEWER}
      ENCRYPTION_SECRET: ${TYPEBOT_ENC_KEY}
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.typebot-viewer.rule=Host(`${DOMAIN_TYPEBOT_VIEWER}`)
        - traefik.http.routers.typebot-viewer.service=typebot-viewer
        - traefik.http.routers.typebot-viewer.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.typebot-viewer.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.typebot-viewer.loadbalancer.server.port=3000
      restart_policy:
        condition: on-failure
TYPEBOT_EOF

    [ "$ENABLE_WORDPRESS" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'WP_EOF'

  wordpress:
    image: wordpress:latest
    networks: 
      - traefik-net
    ports:
      - target: 80
        published: ${WORDPRESS_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      WORDPRESS_DB_HOST: mysql
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: ${WP_DB_PASS}
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.wordpress.rule=Host(`${DOMAIN_WORDPRESS}`)
        - traefik.http.routers.wordpress.service=wordpress
        - traefik.http.routers.wordpress.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.wordpress.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.wordpress.loadbalancer.server.port=80
      restart_policy:
        condition: on-failure
WP_EOF

    [ "$ENABLE_RABBIT" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'RABBIT_EOF'

  rabbitmq:
    image: rabbitmq:3-management-alpine
    networks: 
      - traefik-net
    ports:
      - target: 5672
        published: ${RABBIT_AMQP_PUBLISHED_PORT}
        protocol: tcp
        mode: host
      - target: 15672
        published: ${RABBIT_MGMT_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      RABBITMQ_DEFAULT_USER: admin
      RABBITMQ_DEFAULT_PASS: ${RABBIT_PASS}
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.rabbit.rule=Host(`${DOMAIN_RABBIT}`)
        - traefik.http.routers.rabbit.service=rabbit
        - traefik.http.routers.rabbit.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.rabbit.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.rabbit.loadbalancer.server.port=15672
      restart_policy:
        condition: on-failure
RABBIT_EOF

    [ "$ENABLE_PGADMIN" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'PGADMIN_EOF'

  pgadmin:
    image: dpage/pgadmin4:latest
    networks: 
      - traefik-net
    ports:
      - target: 80
        published: ${PGADMIN_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      PGADMIN_DEFAULT_EMAIL: ${EMAIL_SSL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASS}
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.pgadmin.rule=Host(`${DOMAIN_PGADMIN}`)
        - traefik.http.routers.pgadmin.service=pgadmin
        - traefik.http.routers.pgadmin.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.pgadmin.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.pgadmin.loadbalancer.server.port=80
      restart_policy:
        condition: on-failure
PGADMIN_EOF

    [ "$ENABLE_PMA" = true ] && cat >> $INSTALL_DIR/docker-compose.yml <<'PMA_EOF'

  phpmyadmin:
    image: phpmyadmin:latest
    networks: 
      - traefik-net
    ports:
      - target: 80
        published: ${PMA_PUBLISHED_PORT}
        protocol: tcp
        mode: host
    environment:
      PMA_HOST: mysql
      PMA_PORT: 3306
    deploy:
      mode: replicated
      replicas: 1
      labels:
        - traefik.enable=true
        - traefik.swarm.network=${TRAEFIK_EXTERNAL_NETWORK}
        - traefik.http.routers.pma.rule=Host(`${DOMAIN_PMA}`)
        - traefik.http.routers.pma.service=pma
        - traefik.http.routers.pma.entrypoints=${TRAEFIK_SECURE_ENTRYPOINT}
        - traefik.http.routers.pma.tls.certresolver=${TRAEFIK_CERTRESOLVER_NAME}
        - traefik.http.services.pma.loadbalancer.server.port=80
      restart_policy:
        condition: on-failure
PMA_EOF

    log_info "docker-compose.yml gerado"
}

deploy_stack() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}      IMPLANTANDO STACK${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    cd $INSTALL_DIR
    set -a; source .env 2>/dev/null || true; set +a
    
    # Garantir que variáveis de domínio estão no ambiente (evita Host(``) e "no domain was given")
    if [ -z "$DOMAIN_PORTAINER" ]; then
        log_error "Variáveis de domínio vazias. Edite $INSTALL_DIR/.env e defina DOMAIN_PORTAINER, DOMAIN_N8N, etc., ou execute o instalador novamente."
        exit 1
    fi
    
    reset_stack_volumes

    # Rede: só criar/checar quando usamos proxy EXTERNO (Coolify). Nosso Traefik = rede definida no compose (<stack>_traefik-net)
    if [ "$USE_EXISTING_TRAEFIK" = true ]; then
        if docker network inspect "$TRAEFIK_EXTERNAL_NETWORK" >/dev/null 2>&1; then
            log_info "Rede '${TRAEFIK_EXTERNAL_NETWORK}' já existe (proxy existente)."
        else
            log_info "Criando rede '${TRAEFIK_EXTERNAL_NETWORK}' para integração com proxy..."
            if ! docker network create --driver overlay --attachable --subnet 172.25.0.0/24 "$TRAEFIK_EXTERNAL_NETWORK" 2>/dev/null; then
                log_error "Não foi possível criar ${TRAEFIK_EXTERNAL_NETWORK}. Crie manualmente e rode novamente."
                exit 1
            fi
        fi
    else
        echo -e "${CYAN}Redes overlay atuais no Swarm:${NC}"
        list_overlay_networks || true
        echo -e "${CYAN}Nossa rede (${STACK_NAME}_traefik-net) usará:${NC} ${WHITE}172.25.0.0/24${NC}"
        echo -e "  ${YELLOW}Se aparecer erro 'Pool overlaps': outra rede já usa essa faixa. Rode diagnose-docker-networks.sh e escolha outra subnet.${NC}"
        log_info "Rede será criada pela stack com subnet 172.25.0.0/24"
    fi

    DEPLOY_RAW_LOG="$INSTALL_DIR/${STACK_NAME}-deploy.log"
    DEPLOY_OK=false
    MAX_DEPLOY_ATTEMPTS=6
    ATTEMPT=1

    while [ "$ATTEMPT" -le "$MAX_DEPLOY_ATTEMPTS" ]; do
        if run_command_with_spinner "Implantando stack ${STACK_NAME} (tentativa ${ATTEMPT}/${MAX_DEPLOY_ATTEMPTS})" "$DEPLOY_RAW_LOG" docker stack deploy -c docker-compose.yml "$STACK_NAME"; then
            DEPLOY_OK=true
            break
        fi

        CONFLICT_PORT=$(extract_conflict_port_from_log "$DEPLOY_RAW_LOG")
        if [ -n "$CONFLICT_PORT" ]; then
            if remap_port_if_conflict "$CONFLICT_PORT"; then
                log_warn "Conflito detectado na porta ${CONFLICT_PORT}. Remapeando automaticamente e reaplicando firewall..."
                open_firewall_ports
                generate_files
                cd $INSTALL_DIR
                set -a; source .env 2>/dev/null || true; set +a
                ATTEMPT=$((ATTEMPT + 1))
                continue
            fi
        fi
        break
    done

    if [ "$DEPLOY_OK" != true ]; then
        log_error "Falha crítica no deploy!"
        echo -e "${YELLOW}Veja os detalhes técnicos em:${NC} ${WHITE}${DEPLOY_RAW_LOG}${NC}"
        exit 1
    fi
    
    sleep 20
    
    if [ "$NEED_POSTGRES" = true ]; then
        echo -e "\n${CYAN}Verificando Banco de Dados...${NC}"
        sleep 10
        PG_CONTAINER=$(docker ps -q -f name="${STACK_NAME}_postgres" | head -n1)
        if [ -n "$PG_CONTAINER" ]; then
            log_info "Criando bancos adicionais se necessário..."
            [ "$ENABLE_EVOLUTION" = true ] && {
                docker exec $PG_CONTAINER psql -U n8n_user -d postgres -c "CREATE USER evolution WITH PASSWORD '$PG_PASS_EVO';" 2>/dev/null || true
                docker exec $PG_CONTAINER psql -U n8n_user -d postgres -c "CREATE DATABASE evolution OWNER evolution;" 2>/dev/null || true
            }
            [ "$ENABLE_TYPEBOT" = true ] && {
                docker exec $PG_CONTAINER psql -U n8n_user -d postgres -c "CREATE USER typebot WITH PASSWORD '$PG_PASS_TYPEBOT';" 2>/dev/null || true
                docker exec $PG_CONTAINER psql -U n8n_user -d postgres -c "CREATE DATABASE typebot OWNER typebot;" 2>/dev/null || true
            }
        fi
    fi
    
    log_info "Stack implantada com sucesso!"
    sleep 2
}

install_maintenance_script() {
    print_header
    echo -e "${CYAN}══════════════════════════════════${NC}"
    echo -e "${CYAN}      INSTALANDO MANUTENÇÃO${NC}"
    echo -e "${CYAN}══════════════════════════════════${NC}\n"
    
    MAINT_SCRIPT="/usr/local/bin/twobrain-maintenance.sh"
    
    cat > "$MAINT_SCRIPT" <<'MAINT_EOF'
#!/usr/bin/env bash
# TWOBRAIN Maintenance Script
# Execução automática diária

LOG="/var/log/twobrain-maintenance.log"
echo "=== TWOBRAIN Maintenance - $(date) ===" >> "$LOG"

# Limpeza de memória cache
FREE_MEM=$(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END{print int(100*a/t)}' /proc/meminfo)
if [ "$FREE_MEM" -lt 20 ]; then
    sync; echo 3 > /proc/sys/vm/drop_caches
    echo "  Cache limpo" >> "$LOG"
fi

# Limpeza Docker
docker system prune -af --filter "until=24h" >> "$LOG" 2>&1
docker volume prune -f >> "$LOG" 2>&1

echo "=== Manutenção concluída ===" >> "$LOG"
MAINT_EOF
    
    chmod +x "$MAINT_SCRIPT"
    # Crontab: uso de arquivo temporário para evitar falha quando não existe crontab (exit 1)
    if command -v crontab >/dev/null 2>&1; then
        CRON_TMP=$(mktemp 2>/dev/null || echo "/tmp/twobrain_cron_$$")
        (crontab -l 2>/dev/null || true) | grep -v "twobrain-maintenance" > "${CRON_TMP}.new" || true
        echo "0 3 * * * $MAINT_SCRIPT" >> "${CRON_TMP}.new"
        if crontab "${CRON_TMP}.new" 2>/dev/null; then
            log_info "Script de manutenção instalado (Diário 03:00)"
        else
            log_warn "Crontab não instalado (verifique se o serviço cron está disponível)"
        fi
        rm -f "${CRON_TMP}" "${CRON_TMP}.new" 2>/dev/null || true
    else
        log_warn "Comando crontab não encontrado; agendamento manual necessário"
    fi
}

install_logs_script() {
    LOGS_SCRIPT="/usr/local/bin/twobrain-logs.sh"
    cat > "$LOGS_SCRIPT" <<LOGS_EOF
#!/usr/bin/env bash
# TWOBRAIN - Ver logs da stack (Traefik por padrão)
# Uso: twobrain-logs.sh [serviço]   ou   twobrain-logs.sh list
STACK="$STACK_NAME"
if [ "\$1" = "list" ] || [ "\$1" = "ls" ]; then
    docker stack services "\$STACK"
    echo ""
    echo "Exemplo: twobrain-logs.sh traefik   ou   twobrain-logs.sh portainer"
    exit 0
fi
SVC="\${1:-traefik}"
docker service logs -f "\${STACK}_\${SVC}" 2>/dev/null || echo "Serviço \${STACK}_\${SVC} não encontrado. Use: twobrain-logs.sh list"
LOGS_EOF
    chmod +x "$LOGS_SCRIPT"
    log_info "Script de logs instalado: $LOGS_SCRIPT"
}

generate_report() {
    clear
    echo -e "${MAGENTA}════════════════════════════════════════════${NC}"
    echo -e "${WHITE}${BOLD}   TWOBRAIN - IMPLANTAÇÃO CONCLUÍDA!${NC}"
    echo -e "${MAGENTA}════════════════════════════════════════════${NC}\n"
    
    SERVER_IP=$(get_public_ipv4)
    
    echo -e "${CYAN}📋 RESUMO DA IMPLANTAÇÃO${NC}"
    echo -e "${GREEN}✓${NC} Docker Swarm: ${WHITE}ATIVO${NC}"
    echo -e "${GREEN}✓${NC} Stack: ${WHITE}${STACK_NAME}${NC}"
    echo -e "${GREEN}✓${NC} Política de dados: ${WHITE}reinstalação limpa (volumes da stack zerados)${NC}"
    echo -e "${GREEN}✓${NC} IP do Servidor (público para DNS): ${WHITE}${SERVER_IP}${NC}"
    echo -e "${GREEN}✓${NC} Manutenção: ${WHITE}DIÁRIA 03:00${NC}"
    if [ "$USE_EXISTING_TRAEFIK" = true ]; then
        echo -e "${GREEN}✓${NC} Proxy: ${WHITE}Usando Traefik/Coolify existente${NC} (stack sem serviço Traefik)"
        echo -e "${GREEN}✓${NC} Rede proxy: ${WHITE}${TRAEFIK_EXTERNAL_NETWORK}${NC}"
    elif [ "$TRAEFIK_ALT_PORTS" = true ]; then
        echo -e "${GREEN}✓${NC} Proxy: ${WHITE}Traefik em portas 8081 (HTTP) e 8444 (HTTPS)${NC}"
        echo -e "${GREEN}✓${NC} Rede da stack: ${WHITE}${STACK_NAME}_traefik-net${NC}"
    else
        echo -e "${GREEN}✓${NC} Proxy: ${WHITE}Traefik próprio em 80/443${NC}"
        echo -e "${GREEN}✓${NC} Rede da stack: ${WHITE}${STACK_NAME}_traefik-net${NC}"
    fi
    echo ""
    
    echo -e "${CYAN}🌐 CONFIGURE ESTES DNS (Tipo A):${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}Aponte para: ${GREEN}${SERVER_IP}${NC}\n"
    echo "  $DOMAIN_PORTAINER"
    [ "$ENABLE_MINIO" = true ] && {
        echo "  $DOMAIN_MINIO_CONSOLE"
        echo "  $DOMAIN_MINIO_API"
    }
    [ "$ENABLE_N8N" = true ] && {
        echo "  $DOMAIN_N8N"
        echo "  $DOMAIN_N8N_WEBHOOK"
    }
    [ "$ENABLE_TYPEBOT" = true ] && {
        echo "  $DOMAIN_TYPEBOT"
        echo "  $DOMAIN_TYPEBOT_VIEWER"
    }
    [ "$ENABLE_EVOLUTION" = true ] && echo "  $DOMAIN_EVOLUTION"
    [ "$ENABLE_WORDPRESS" = true ] && echo "  $DOMAIN_WORDPRESS"
    [ "$ENABLE_RABBIT" = true ] && echo "  $DOMAIN_RABBIT"
    [ "$ENABLE_PGADMIN" = true ] && echo "  $DOMAIN_PGADMIN"
    [ "$ENABLE_PMA" = true ] && echo "  $DOMAIN_PMA"
    
    echo -e "\n${CYAN}🔐 ACESSOS E CREDENCIAIS${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    echo -e "${WHITE}Portainer${NC}: https://$DOMAIN_PORTAINER"
    echo -e "  • Senha definida no primeiro acesso\n"

    if [ "$USE_EXISTING_TRAEFIK" != true ]; then
        echo -e "${WHITE}Traefik Dashboard${NC}: https://$DOMAIN_TRAEFIK"
        echo -e "  • Usuário: ${WHITE}admin${NC}"
        echo -e "  • Senha:   ${WHITE}$TRAEFIK_PASS${NC}\n"
    fi

    [ "$ENABLE_MINIO" = true ] && {
        echo -e "${WHITE}MinIO Console${NC}: https://$DOMAIN_MINIO_CONSOLE"
        echo -e "  • Usuário: ${WHITE}$MINIO_ROOT_USER${NC}"
        echo -e "  • Senha:   ${WHITE}$MINIO_ROOT_PASSWORD${NC}\n"
    }

    [ "$ENABLE_EVOLUTION" = true ] && {
        echo -e "${WHITE}Evolution API${NC}: https://$DOMAIN_EVOLUTION"
        echo -e "  • API Key: ${WHITE}$EVO_API_KEY${NC}\n"
    }

    [ "$ENABLE_RABBIT" = true ] && {
        echo -e "${WHITE}RabbitMQ${NC}: https://$DOMAIN_RABBIT"
        echo -e "  • Usuário: ${WHITE}admin${NC}"
        echo -e "  • Senha:   ${WHITE}$RABBIT_PASS${NC}\n"
    }

    [ "$ENABLE_PGADMIN" = true ] && {
        echo -e "${WHITE}pgAdmin${NC}: https://$DOMAIN_PGADMIN"
        echo -e "  • Email: ${WHITE}$EMAIL_SSL${NC}"
        echo -e "  • Senha: ${WHITE}$PGADMIN_PASS${NC}\n"
    }

    [ "$ENABLE_PMA" = true ] && {
        echo -e "${WHITE}phpMyAdmin${NC}: https://$DOMAIN_PMA"
        echo -e "  • Login usa credenciais do MySQL (root ou usuário do banco)\n"
    }

    echo -e "${CYAN}🗄️  COMO CONECTAR NOS BANCOS${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    [ "$NEED_MYSQL" = true ] && [ "$EXPOSE_DB_PORTS" = true ] && {
        echo -e "${WHITE}MySQL${NC} (externo: Power BI, DBeaver, TablePlus)"
        echo -e "  • Host: ${WHITE}${SERVER_IP}${NC}"
        echo -e "  • Porta: ${WHITE}${MYSQL_PUBLISHED_PORT}${NC}"
        echo -e "  • Usuário admin: ${WHITE}root${NC}"
        echo -e "  • Senha admin: ${WHITE}${MYSQL_ROOT_PASS}${NC}"
        echo -e "  • Banco app: ${WHITE}wordpress${NC}"
        echo -e "  • Usuário app: ${WHITE}wordpress${NC}"
        echo -e "  • Senha app: ${WHITE}${WP_DB_PASS}${NC}\n"
    }

    [ "$NEED_POSTGRES" = true ] && [ "$EXPOSE_DB_PORTS" = true ] && {
        echo -e "${WHITE}PostgreSQL${NC} (externo: pgAdmin, DBeaver, DataGrip)"
        echo -e "  • Host: ${WHITE}${SERVER_IP}${NC}"
        echo -e "  • Porta: ${WHITE}${POSTGRES_PUBLISHED_PORT}${NC}"
        echo -e "  • Usuário base (n8n): ${WHITE}n8n_user${NC}"
        echo -e "  • Senha base: ${WHITE}${PG_PASS_N8N}${NC}"
        echo -e "  • Banco base: ${WHITE}n8n${NC}"
        [ "$ENABLE_EVOLUTION" = true ] && {
            echo -e "  • Evolution -> DB: ${WHITE}evolution${NC} | User: ${WHITE}evolution${NC} | Pass: ${WHITE}${PG_PASS_EVO}${NC}"
        }
        [ "$ENABLE_TYPEBOT" = true ] && {
            echo -e "  • Typebot  -> DB: ${WHITE}typebot${NC} | User: ${WHITE}typebot${NC} | Pass: ${WHITE}${PG_PASS_TYPEBOT}${NC}"
        }
        echo ""
    }

    [ "$NEED_REDIS" = true ] && [ "$EXPOSE_DB_PORTS" = true ] && {
        echo -e "${WHITE}Redis${NC} (externo: redis-cli, RedisInsight)"
        echo -e "  • Host: ${WHITE}${SERVER_IP}${NC}"
        echo -e "  • Porta: ${WHITE}${REDIS_PUBLISHED_PORT}${NC}"
        echo -e "  • Senha: ${WHITE}${REDIS_PASS}${NC}"
        echo -e "  • Exemplo redis-cli: ${WHITE}redis-cli -h ${SERVER_IP} -p ${REDIS_PUBLISHED_PORT} -a ${REDIS_PASS}${NC}\n"
    }
    
    echo -e "${CYAN}📁 ARQUIVOS${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Config: ${WHITE}$INSTALL_DIR/.env${NC}"
    echo -e "  Compose: ${WHITE}$INSTALL_DIR/docker-compose.yml${NC}"
    echo -e "  Tutorial Cloudflare + portas: ${WHITE}$INSTALL_DIR/CLOUDFLARE-E-PORTAS.txt${NC}"
    echo -e "  Manutenção: ${WHITE}/usr/local/bin/twobrain-maintenance.sh${NC}"
    echo -e "  Logs: ${WHITE}/usr/local/bin/twobrain-logs.sh${NC}\n"
    
    echo -e "${CYAN}☁️  CLOUDFLARE E PORTAS (resumo)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    build_port_items
    PORTS_CSV=""
    for item in "${PORT_ITEMS[@]}"; do
        port="${item%%:*}"
        PORTS_CSV="${PORTS_CSV:+${PORTS_CSV}, }${port}"
    done
    echo -e "  No painel da VPS/cloud, libere: ${WHITE}TCP ${PORTS_CSV}${NC}"
    echo -e "  Cloudflare: SSL ${WHITE}Full${NC} ou ${WHITE}Full (strict)${NC}; Proxy ${WHITE}laranja${NC} (Proxied) ou cinza (DNS only)"
    echo -e "  Tutorial completo: ${WHITE}$INSTALL_DIR/CLOUDFLARE-E-PORTAS.txt${NC}\n"
    
    echo -e "${CYAN}📜 VER LOGS${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Listar serviços:  ${WHITE}docker stack services ${STACK_NAME}${NC}"
    if [ "$USE_EXISTING_TRAEFIK" != true ]; then
        echo -e "  Logs Traefik:      ${WHITE}docker service logs -f ${STACK_NAME}_traefik${NC}"
    fi
    echo -e "  Ou use o script:  ${WHITE}twobrain-logs.sh list${NC}     (lista serviços)"
    echo -e "                    ${WHITE}twobrain-logs.sh portainer${NC} (ou n8n_editor, etc.)\n"
    
    echo -e "${CYAN}⏱️  PRÓXIMOS PASSOS${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$USE_EXISTING_TRAEFIK" = true ]; then
        echo -e "1. No Coolify/proxy existente: adicione os hosts (portainer, n8n, etc.) apontando para os serviços desta stack na rede ${TRAEFIK_EXTERNAL_NETWORK}."
        echo -e "2. Ou configure DNS (Tipo A) para ${WHITE}${SERVER_IP}${NC} e use o proxy existente para rotear por host."
    else
        echo -e "1. No Cloudflare: proxy laranja (Proxied) ou cinza (DNS only); SSL Full ou Full (strict)"
        echo -e "2. No painel da VPS/cloud: libere ${WHITE}TCP ${PORTS_CSV}${NC} (sem isso não há autenticação/acesso)"
        echo -e "3. Configure os registros DNS acima apontando para ${WHITE}${SERVER_IP}${NC}"
        [ "$TRAEFIK_ALT_PORTS" = true ] && echo -e "   ${YELLOW}Acesso direto (portas alt): http://${SERVER_IP}:${TRAEFIK_HTTP_PORT} e https://${SERVER_IP}:${TRAEFIK_HTTPS_PORT}${NC}"
    fi
    echo -e "4. Aguarde 2-5 min para os serviços subirem; até 10 min para certificados SSL"
    echo -e "5. Teste: ${WHITE}https://$DOMAIN_PORTAINER${NC}\n"

    echo -e "${CYAN}🧱 INFORMAÇÕES BRUTAS (DEBUG)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Deploy log: ${WHITE}$INSTALL_DIR/${STACK_NAME}-deploy.log${NC}"
    echo -e "  Serviços:   ${WHITE}docker stack services ${STACK_NAME}${NC}"
    echo -e "  Logs proxy: ${WHITE}docker service logs -f ${STACK_NAME}_traefik${NC}"
    echo -e "  Acme:       ${WHITE}$INSTALL_DIR/traefik/acme.json${NC}\n"
    if [ "$EXPOSE_DB_PORTS" != true ]; then
        echo -e "${YELLOW}Observação:${NC} portas de banco não foram expostas no host (modo integração)."
        echo -e "Acesso aos bancos deve ser via rede interna Docker/Swarm.\n"
    fi

    if [ -n "$AUTO_PORT_CHANGES" ]; then
        echo -e "${CYAN}🔁 AJUSTES AUTOMÁTICOS DE PORTA${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        printf "%b" "$AUTO_PORT_CHANGES"
        echo -e ""
    fi
    
    echo -e "${GREEN}${BOLD}✓ Instalação concluída!${NC}\n"
    echo -e "${MAGENTA}════════════════════════════════════════════${NC}\n"
}

main() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}Execute como root${NC}"; exit 1; }
    mkdir -p "$INSTALL_DIR"
    load_state
    ask_stack_name
    ask_cleanup
    install_base_deps
    ask_swarm_integration_mode
    ask_traefik_mode
    selection_menu
    configure_port_profile
    open_firewall_ports
    collect_info
    generate_files
    deploy_stack
    install_maintenance_script
    install_logs_script
    generate_report
}

main "$@"
