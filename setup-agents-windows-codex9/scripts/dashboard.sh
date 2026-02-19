#!/usr/bin/env bash
# ============================================================================
# WORKER DASHBOARD — Shown when terminal tabs finish formatting
# ============================================================================

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

clear

# Get terminal dimensions
COLS=$(tput cols 2>/dev/null || echo 80)

# Center helper function
center() {
    local text="$1"
    local width=${#text}
    local padding=$(( (COLS - width) / 2 ))
    printf "%*s%s\n" $padding "" "$text"
}

# Draw header box
draw_box() {
    local text="$1"
    local color="$2"
    local width=$((${#text} + 4))
    local padding=$(( (COLS - width) / 2 ))
    
    printf "%*s" $padding ""
    printf "${color}╔"
    printf '═%.0s' $(seq 1 $((width - 2)))
    printf "╗${NC}\n"
    
    printf "%*s" $padding ""
    printf "${color}║${NC} ${WHITE}${BOLD}%s${NC} ${color}║${NC}\n" "$text"
    
    printf "%*s" $padding ""
    printf "${color}╚"
    printf '═%.0s' $(seq 1 $((width - 2)))
    printf "╝${NC}\n"
}

echo ""
echo ""

# ASCII Art Banner
echo -e "${CYAN}"
center "██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗██████╗ ███████╗"
center "██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝██╔══██╗██╔════╝"
center "██║ █╗ ██║██║   ██║██████╔╝█████╔╝ █████╗  ██████╔╝███████╗"
center "██║███╗██║██║   ██║██╔══██╗██╔═██╗ ██╔══╝  ██╔══██╗╚════██║"
center "╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████╗██║  ██║███████║"
center " ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝"
echo -e "${NC}"

echo ""
draw_box "MULTI-AGENT WORKER POOL" "${BLUE}"
echo ""

# System Status
echo -e "${WHITE}${BOLD}System Status${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"
echo ""

# Current time
echo -e "  ${GREEN}●${NC}  ${WHITE}Started:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Worker count info
if [ -n "$WORKER_COUNT" ]; then
    echo -e "  ${CYAN}◆${NC}  ${WHITE}Workers Active:${NC} $WORKER_COUNT"
else
    echo -e "  ${CYAN}◆${NC}  ${WHITE}Workers:${NC} Initializing..."
fi

echo ""

# Architecture
echo -e "${WHITE}${BOLD}Architecture${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${BLUE}⬤${NC}  Master-1: ${DIM}Interface (Your terminal)${NC}"
echo -e "  ${MAGENTA}⬤${NC}  Master-2: ${DIM}Architect (Decomposes requests)${NC}"
echo -e "  ${YELLOW}⬤${NC}  Master-3: ${DIM}Allocator (Routes to workers)${NC}"
echo -e "  ${GREEN}⬤${NC}  Workers:  ${DIM}Isolated execution per domain${NC}"
echo ""

# Instructions
echo -e "${WHITE}${BOLD}Worker Workflow${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${GREEN}1.${NC}  Workers launch on demand when assigned"
echo -e "  ${GREEN}2.${NC}  Domain isolation ensures code safety"
echo -e "  ${GREEN}3.${NC}  Auto-reset after 6 tasks (or budget cap)"
echo -e "  ${GREEN}4.${NC}  PR creation on task completion"
echo ""

# Footer
echo -e "${DIM}─────────────────────────────────────────${NC}"
center "Press any key to continue or Ctrl+C to exit"
echo ""

read -n 1 -s
