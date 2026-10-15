#!/bin/bash

# Gestion du site table-to-gmail.italic.dev
#
# Le site tient dans une page statique unique, servie depuis www/. Tout ce qui
# vit à la racine du dépôt, ce script le premier, reste ainsi hors du
# documentroot : sur www7 celui-ci pointe sur httpdocs/www, tandis que le dépôt
# Plesk déploie, lui, dans httpdocs. Un .htaccess n'y suffirait pas : nginx sert
# les fichiers statiques lui-même et ne le lit pas.
#
# Sans argument, le script ouvre son menu. Les commandes restent utilisables
# directement : ./manage.sh {start|stop|restart|status|deploy}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCROOT="$SCRIPT_DIR/www"
PORT="${PORT:-8099}"
PID_FILE="$SCRIPT_DIR/.serve.pid"
LOG_FILE="$SCRIPT_DIR/.serve.log"

# Production. Le dépôt Plesk est en mode pull manuel : le webhook existe mais
# reste débranché, un push ne déploie donc rien tout seul. C'est voulu.
SERVER="www7"
DOMAIN="table-to-gmail.italic.dev"
REPO="table-to-gmail"
BRANCH="master"
URL="https://$DOMAIN/"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${YELLOW}$*${NC}"; }
ok()    { echo -e "${GREEN}$*${NC}"; }
fail()  { echo -e "${RED}$*${NC}" >&2; }

# PID du serveur local s'il tourne vraiment, vide sinon : un fichier PID
# rescapé d'un arrêt brutal ne doit pas faire croire à un serveur vivant.
running_pid() {
    [ -f "$PID_FILE" ] || return 0
    local pid
    pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
    else
        rm -f "$PID_FILE"
    fi
}

# PID qui écoute sur le port, qu'il vienne de ce script ou non : un serveur
# lancé à la main dans un autre terminal est le cas le plus fréquent, et le
# script doit savoir le nommer plutôt que buter dessus.
listening_pid() {
    command -v ss >/dev/null 2>&1 || return 0
    ss -lptn "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
}

pid_cmd() {
    ps -p "$1" -o args= 2>/dev/null
}

# Une ligne d'état, pour le menu comme pour « status ».
local_state() {
    local pid
    pid="$(running_pid)"
    if [ -n "$pid" ]; then
        echo -e "${GREEN}(lancé, PID $pid)${NC}"
        return
    fi
    pid="$(listening_pid)"
    if [ -n "$pid" ]; then
        echo -e "${GREEN}(lancé hors de ce script, PID $pid)${NC}"
    else
        echo -e "${YELLOW}(arrêté)${NC}"
    fi
}

start() {
    local pid
    pid="$(running_pid)"
    if [ -n "$pid" ]; then
        ok "Déjà lancé (PID $pid) : http://localhost:$PORT"
        return 0
    fi
    pid="$(listening_pid)"
    if [ -n "$pid" ]; then
        fail "Port $PORT déjà pris par le PID $pid, que ce script n'a pas lancé :"
        echo "  $(pid_cmd "$pid")"
        info "« stop » sait l'arrêter s'il sert bien la page ; sinon changez de port : PORT=8098 $0 start"
        return 1
    fi
    python3 -m http.server "$PORT" --bind 127.0.0.1 -d "$DOCROOT" >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    sleep 1
    pid="$(running_pid)"
    if [ -z "$pid" ]; then
        # Le cas courant est un port déjà pris : la dernière ligne de la trace
        # Python le dit, le reste ne sert à rien à l'écran.
        fail "Démarrage impossible sur le port $PORT : $(tail -1 "$LOG_FILE")"
        info "Trace complète dans $LOG_FILE"
        return 1
    fi
    ok "Serveur lancé (PID $pid) : http://localhost:$PORT"
}

stop() {
    local pid
    pid="$(running_pid)"
    if [ -z "$pid" ]; then
        pid="$(listening_pid)"
        if [ -z "$pid" ]; then
            info "Aucun serveur sur le port $PORT."
            return 0
        fi
        # On n'arrête d'office qu'un serveur du même genre que le nôtre. Tout
        # autre programme qui écouterait là relève d'une décision humaine.
        local cmd
        cmd="$(pid_cmd "$pid")"
        if [[ "$cmd" != *http.server* ]]; then
            fail "Le port $PORT est tenu par le PID $pid, que ce script n'a pas lancé :"
            echo "  $cmd"
            info "Arrêtez-le vous-même si c'est bien ce que vous voulez : kill $pid"
            return 1
        fi
        info "Serveur lancé hors de ce script (PID $pid), arrêt quand même."
    fi
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null
    rm -f "$PID_FILE"
    ok "Serveur arrêté (PID $pid)."
}

status() {
    echo -e "${YELLOW}Local   :${NC} $(local_state) http://localhost:$PORT"

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)"
    if [ "$code" = "200" ]; then
        ok "Prod    : $URL répond $code"
    else
        fail "Prod    : $URL répond ${code:-aucune réponse}"
    fi

    echo
    info "Dernier commit local  : $(git -C "$SCRIPT_DIR" log -1 --oneline)"
    # --get-last-commit répond comme un « git show » : on en tire le hash court
    # et le sujet, pour comparer d'un coup d'œil avec le commit local.
    local deployed
    deployed="$(ssh "$SERVER" "plesk ext git --get-last-commit -domain $DOMAIN -name $REPO" 2>/dev/null \
        | awk '/^commit /{sha=substr($2,1,7)} /^Date:/{getline; getline; sub(/^ +/,""); print sha" "$0; exit}')"
    info "Dernier commit déployé: ${deployed:-inconnu}"
}

# Pousser puis déclencher le déploiement Plesk. L'arbre doit être propre :
# déployer un commit qui ne contient pas ce qu'on a sous les yeux est le plus
# sûr moyen de ne plus savoir ce qui tourne en production.
deploy() {
    if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]; then
        fail "Arbre de travail modifié, commite ou remise d'abord :"
        git -C "$SCRIPT_DIR" status --short >&2
        return 1
    fi

    local pending
    pending="$(git -C "$SCRIPT_DIR" log --oneline "origin/$BRANCH..$BRANCH" 2>/dev/null)"
    if [ -n "$pending" ]; then
        info "À pousser sur origin/$BRANCH :"
        echo "$pending"
        git -C "$SCRIPT_DIR" push origin "$BRANCH" || return 1
    else
        info "Rien à pousser, origin/$BRANCH est à jour."
    fi

    info "Déploiement sur $SERVER…"
    ssh "$SERVER" "plesk ext git --fetch -domain $DOMAIN -name $REPO && plesk ext git --deploy -domain $DOMAIN -name $REPO" || return 1

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "$URL")"
    if [ "$code" = "200" ]; then
        ok "Déployé, $URL répond $code"
    else
        fail "Déployé, mais $URL répond $code, à vérifier."
        return 1
    fi
}

usage() {
    cat <<EOF
Usage : ./manage.sh [commande]

  start     lance le serveur local sur http://localhost:$PORT (dossier www/)
  stop      arrête ce serveur
  restart   les deux
  status    état du serveur local, de la production, et commits comparés
  deploy    pousse sur GitHub puis déploie sur $SERVER ($DOMAIN)

Sans commande, le menu s'ouvre.
Le port se surcharge par l'environnement : PORT=8098 ./manage.sh start
EOF
}

pause() {
    echo
    read -rp "Entrée pour revenir au menu… " _ || true
}

show_menu() {
    clear
    local state
    state="$(local_state)"

    echo -e "${GREEN}table-to-gmail${NC}  $DOMAIN"
    echo
    echo -e "  ${YELLOW}l)${NC} Lancer le serveur local"
    echo -e "  ${YELLOW}a)${NC} Arrêter le serveur local"
    echo -e "  ${YELLOW}r)${NC} Relancer le serveur local"
    echo -e "  ${YELLOW}e)${NC} État : local, production, commits"
    echo -e "  ${YELLOW}d)${NC} Déployer sur $SERVER"
    echo
    echo -e "  ${RED}q)${NC} Quitter"
    echo
    echo -e "  Local        ${GREEN}http://localhost:$PORT${NC}  $state"
    echo -e "  Production   ${GREEN}$URL${NC}"
    echo
}

# Boucle du menu. Un read qui échoue signale une entrée fermée (script appelé
# sans terminal) : on sort, plutôt que de tourner à vide indéfiniment.
menu() {
    local choix
    while true; do
        show_menu
        read -rp "Votre choix : " choix || { echo; exit 0; }
        case "$choix" in
            l|L) echo; start;        pause ;;
            a|A) echo; stop;         pause ;;
            r|R) echo; stop && start; pause ;;
            e|E) echo; status;       pause ;;
            d|D) echo; deploy;       pause ;;
            q|Q) clear; exit 0 ;;
            *) ;;
        esac
    done
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop && start ;;
    status)  status ;;
    deploy)  deploy ;;
    "")      menu ;;
    *)       usage; exit 1 ;;
esac
