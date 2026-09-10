#!/usr/bin/env bash
#
# ai-cli-cleaner.sh — detecta e remove CLIs de IA instaladas no sistema (Linux).
# Documentação: docs/linux/sistema/ai-cli-cleaner.md
#
# Uso:
#   ./ai-cli-cleaner.sh            fluxo interativo completo
#   ./ai-cli-cleaner.sh --scan     só escaneia e mostra o relatório
#   ./ai-cli-cleaner.sh --dry-run  roda o fluxo todo sem alterar nada
#   ./ai-cli-cleaner.sh --help

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuração / estado global
# ---------------------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
STATE_DIR="$HOME/.ai-cli-cleaner"
LOG_DIR="$STATE_DIR/logs"
BACKUP_ROOT="$STATE_DIR/backups"
LOG_FILE="$LOG_DIR/ai-cli-cleaner-$TIMESTAMP.log"

DRY_RUN=0
SCAN_ONLY=0
ASSUME_YES=0

# id|Nome de exibição|binários(csv)|pacotes npm(csv)|pacotes pip/pipx(csv)|diretórios(csv)
TOOLS=(
  "claude|Claude Code (Anthropic)|claude|@anthropic-ai/claude-code||$HOME/.claude,$HOME/.claude.json,$HOME/.config/claude,$HOME/.cache/claude,$HOME/.local/share/claude"
  "gemini|Gemini CLI (Google)|gemini|@google/gemini-cli||$HOME/.gemini,$HOME/.config/gemini,$HOME/.cache/gemini,$HOME/.local/share/gemini"
  "antigravity|Antigravity (Google)|antigravity|||$HOME/.antigravity,$HOME/.config/antigravity,$HOME/.config/Antigravity,$HOME/.cache/antigravity,$HOME/.local/share/antigravity"
  "kimi|Kimi CLI (Moonshot AI)|kimi|kimi-cli,@moonshot-ai/kimi-cli||$HOME/.kimi,$HOME/.config/kimi,$HOME/.cache/kimi"
  "codex|Codex CLI (OpenAI)|codex|@openai/codex||$HOME/.codex,$HOME/.config/codex,$HOME/.cache/codex"
  "copilot|GitHub Copilot CLI|copilot,gh-copilot|@githubnext/github-copilot-cli||$HOME/.copilot,$HOME/.config/gh-copilot,$HOME/.config/github-copilot"
  "cursor-agent|Cursor CLI|cursor-agent|||$HOME/.cursor,$HOME/.config/Cursor,$HOME/.config/cursor-agent"
  "aider|Aider|aider||aider-chat|$HOME/.aider,$HOME/.aider.conf.yml,$HOME/.aider.tags.cache.v3,$HOME/.config/aider,$HOME/.cache/aider"
  "q|Amazon Q CLI|q||amazon-q-cli|$HOME/.config/amazon-q,$HOME/.local/share/amazon-q"
  "qwen|Qwen Code CLI|qwen|@qwen-code/qwen-code||$HOME/.qwen,$HOME/.config/qwen,$HOME/.cache/qwen"
  "opencode|opencode|opencode||opencode-ai|$HOME/.opencode,$HOME/.config/opencode,$HOME/.local/share/opencode"
  "goose|Goose (Block)|goose|||$HOME/.config/goose,$HOME/.local/share/goose,$HOME/.cache/goose"
  "ollama|Ollama|ollama|||$HOME/.ollama"
  "interpreter|Open Interpreter|interpreter||open-interpreter|$HOME/.interpreter,$HOME/.config/open-interpreter,$HOME/.cache/open-interpreter,$HOME/.local/share/open-interpreter"
  "llm|llm (Simon Willison)|llm||llm|$HOME/.config/io.datasette.llm"
  "grok|Grok CLI (xAI)|grok|@xai/grok-cli||$HOME/.grok,$HOME/.config/grok"
  "deepseek|DeepSeek CLI|deepseek|deepseek-cli||$HOME/.deepseek,$HOME/.config/deepseek"
)

HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

NPM_GLOBAL_LIST=""
PIP_LIST=""
PIPX_LIST=""

# resultados da varredura: tool_id -> lista de evidências (uma por linha, campo\tcampo)
declare -A FOUND_EVIDENCE
declare -A FOUND_SIZE

# ---------------------------------------------------------------------------
# Helpers de log / saída
# ---------------------------------------------------------------------------

log() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; log "INFO: $1"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"; log "OK: $1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; log "WARN: $1"; }
err()  { printf '\033[1;31m[ERRO]\033[0m %s\n' "$1" >&2; log "ERRO: $1"; }

usage() {
  cat <<'EOF'
ai-cli-cleaner.sh — detecta e remove CLIs de IA instaladas no sistema.

Uso:
  ./ai-cli-cleaner.sh            fluxo interativo completo
  ./ai-cli-cleaner.sh --scan     só escaneia e mostra o relatório, não remove nada
  ./ai-cli-cleaner.sh --dry-run  roda o fluxo todo mas só mostra o que faria
  ./ai-cli-cleaner.sh --yes      pula a confirmação por escrito (ainda pergunta y/n)
  ./ai-cli-cleaner.sh --help     mostra esta ajuda
EOF
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --scan) SCAN_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Argumento desconhecido: $arg"; usage; exit 1 ;;
  esac
done

if [[ "$EUID" -eq 0 ]]; then
  err "Não execute este script como root — ele opera sobre o \$HOME do usuário atual."
  exit 1
fi

# ---------------------------------------------------------------------------
# Coleta de listas globais (uma vez, para não repetir chamadas lentas)
# ---------------------------------------------------------------------------

collect_global_lists() {
  if command -v npm >/dev/null 2>&1; then
    NPM_GLOBAL_LIST="$(npm ls -g --depth=0 2>/dev/null || true)"
  fi
  if command -v pip3 >/dev/null 2>&1; then
    PIP_LIST="$(pip3 list --disable-pip-version-check 2>/dev/null || true)"
  elif command -v pip >/dev/null 2>&1; then
    PIP_LIST="$(pip list --disable-pip-version-check 2>/dev/null || true)"
  fi
  if command -v pipx >/dev/null 2>&1; then
    PIPX_LIST="$(pipx list --short 2>/dev/null || true)"
  fi
}

# ---------------------------------------------------------------------------
# Detecção
# ---------------------------------------------------------------------------

human_size() {
  local path="$1"
  du -sh "$path" 2>/dev/null | cut -f1
}

scan_tool() {
  local id="$1" bins="$2" npm_pkgs="$3" pip_pkgs="$4" dirs="$5"
  local evidence=()
  local total_size_arg=()

  local b
  IFS=',' read -ra bin_arr <<<"$bins"
  for b in "${bin_arr[@]}"; do
    [[ -z "$b" ]] && continue
    if command -v "$b" >/dev/null 2>&1; then
      evidence+=("bin|$b|$(command -v "$b")")
    fi
  done

  local p
  if [[ -n "$npm_pkgs" ]]; then
    IFS=',' read -ra npm_arr <<<"$npm_pkgs"
    for p in "${npm_arr[@]}"; do
      [[ -z "$p" ]] && continue
      if [[ -n "$NPM_GLOBAL_LIST" ]] && grep -qF "$p" <<<"$NPM_GLOBAL_LIST"; then
        evidence+=("npm|$p|")
      fi
    done
  fi

  if [[ -n "$pip_pkgs" ]]; then
    IFS=',' read -ra pip_arr <<<"$pip_pkgs"
    for p in "${pip_arr[@]}"; do
      [[ -z "$p" ]] && continue
      if [[ -n "$PIP_LIST" ]] && grep -qiF "$p" <<<"$PIP_LIST"; then
        evidence+=("pip|$p|")
      fi
      if [[ -n "$PIPX_LIST" ]] && grep -qiF "$p" <<<"$PIPX_LIST"; then
        evidence+=("pipx|$p|")
      fi
    done
  fi

  local d
  IFS=',' read -ra dir_arr <<<"$dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d" ]]; then
      evidence+=("path|$d|$(human_size "$d")")
      total_size_arg+=("$d")
    fi
  done

  if [[ "${#evidence[@]}" -gt 0 ]]; then
    FOUND_EVIDENCE["$id"]="$(printf '%s\n' "${evidence[@]}")"
    if [[ "${#total_size_arg[@]}" -gt 0 ]]; then
      FOUND_SIZE["$id"]="$(du -ch "${total_size_arg[@]}" 2>/dev/null | tail -1 | cut -f1)"
    else
      FOUND_SIZE["$id"]="-"
    fi
  fi
}

run_scan() {
  info "Coletando listas de pacotes (npm/pip/pipx)..."
  collect_global_lists
  info "Varrendo o sistema em busca de CLIs de IA conhecidas..."
  local entry id display bins npm_pkgs pip_pkgs dirs
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r id display bins npm_pkgs pip_pkgs dirs <<<"$entry"
    scan_tool "$id" "$bins" "$npm_pkgs" "$pip_pkgs" "$dirs"
  done
}

tool_display_name() {
  local id="$1" entry
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r eid edisplay _ <<<"$entry"
    [[ "$eid" == "$id" ]] && { printf '%s' "$edisplay"; return; }
  done
}

tool_fields() {
  # imprime bins/npm_pkgs/pip_pkgs/dirs (separados por \n) para um id
  local id="$1" entry
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r eid _ ebins enpm epip edirs <<<"$entry"
    if [[ "$eid" == "$id" ]]; then
      printf '%s\n%s\n%s\n%s\n' "$ebins" "$enpm" "$epip" "$edirs"
      return
    fi
  done
}

print_report() {
  local any=0
  local id
  for id in "${!FOUND_EVIDENCE[@]}"; do any=1; break; done
  if [[ "$any" -eq 0 ]]; then
    ok "Nenhum rastro de CLI de IA conhecida foi encontrado neste sistema."
    return
  fi
  echo
  printf '\033[1m%-14s %-32s %-10s %s\033[0m\n' "ID" "FERRAMENTA" "TAMANHO" "EVIDÊNCIAS"
  for id in "${!FOUND_EVIDENCE[@]}"; do
    local display size count
    display="$(tool_display_name "$id")"
    size="${FOUND_SIZE[$id]}"
    count="$(printf '%s\n' "${FOUND_EVIDENCE[$id]}" | grep -c .)"
    printf '%-14s %-32s %-10s %s evidência(s)\n' "$id" "$display" "$size" "$count"
  done
  echo
}

# ---------------------------------------------------------------------------
# Seleção (whiptail ou fallback em texto puro)
# ---------------------------------------------------------------------------

select_tools_whiptail() {
  local args=(--title "ai-cli-cleaner" --checklist \
    "CLIs de IA encontradas no sistema.\nSelecione (ESPAÇO) as que deseja remover e confirme com TAB/ENTER:" \
    20 78 10)
  local id
  for id in "${!FOUND_EVIDENCE[@]}"; do
    local display size
    display="$(tool_display_name "$id")"
    size="${FOUND_SIZE[$id]}"
    args+=("$id" "$display ($size)" OFF)
  done
  whiptail "${args[@]}" 3>&1 1>&2 2>&3
}

select_tools_plain() {
  echo "Ferramentas encontradas:"
  local ids=() i=1
  local id
  for id in "${!FOUND_EVIDENCE[@]}"; do
    ids+=("$id")
    printf '  %d) %s (%s) [%s]\n' "$i" "$(tool_display_name "$id")" "${FOUND_SIZE[$id]}" "$id"
    i=$((i + 1))
  done
  echo
  read -r -p "Digite os números a remover, separados por espaço (ou 'todos', vazio para cancelar): " choice
  [[ -z "$choice" ]] && return
  local selected=()
  if [[ "$choice" == "todos" ]]; then
    selected=("${ids[@]}")
  else
    local n
    for n in $choice; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      local idx=$((n - 1))
      if [[ "$idx" -ge 0 && "$idx" -lt "${#ids[@]}" ]]; then
        selected+=("${ids[$idx]}")
      fi
    done
  fi
  printf '%s\n' "${selected[@]}"
}

# ---------------------------------------------------------------------------
# Remoção
# ---------------------------------------------------------------------------

run_cmd() {
  # run_cmd <descrição> -- <comando...>
  local desc="$1"
  shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "[DRY-RUN] $desc: $*"
    return 0
  fi
  if "$@" >>"$LOG_FILE" 2>&1; then
    ok "$desc"
  else
    err "Falhou: $desc (veja $LOG_FILE)"
  fi
}

backup_paths() {
  local id="$1"
  shift
  local paths=("$@")
  [[ "${#paths[@]}" -eq 0 ]] && return
  local tmp_dir="$BACKUP_ROOT/${id}-${TIMESTAMP}"
  local tar_path="$BACKUP_ROOT/${id}-${TIMESTAMP}.tar.gz"
  mkdir -p "$tmp_dir"
  local p
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] || continue
    local safe_name
    safe_name="$(echo "$p" | sed 's#^/##; s#/#_#g')"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      warn "[DRY-RUN] backup de $p -> $tmp_dir/$safe_name"
      continue
    fi
    cp -a "$p" "$tmp_dir/$safe_name" 2>>"$LOG_FILE"
  done
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rmdir "$tmp_dir" 2>/dev/null
    return
  fi
  if tar -czf "$tar_path" -C "$BACKUP_ROOT" "${id}-${TIMESTAMP}" 2>>"$LOG_FILE"; then
    rm -rf "$tmp_dir"
    ok "Backup de $id salvo em $tar_path"
  else
    warn "Não foi possível compactar o backup de $id — arquivos ficaram em $tmp_dir"
  fi
}

remove_tool() {
  local id="$1" do_backup="$2"
  local bins npm_pkgs pip_pkgs dirs
  mapfile -t fields < <(tool_fields "$id")
  bins="${fields[0]}"; npm_pkgs="${fields[1]}"; pip_pkgs="${fields[2]}"; dirs="${fields[3]}"

  info "=== Removendo: $(tool_display_name "$id") ==="

  if [[ "$do_backup" == "yes" ]]; then
    local dir_arr=()
    IFS=',' read -ra dir_arr <<<"$dirs"
    backup_paths "$id" "${dir_arr[@]}"
  fi

  local p
  if [[ -n "$npm_pkgs" ]]; then
    IFS=',' read -ra npm_arr <<<"$npm_pkgs"
    for p in "${npm_arr[@]}"; do
      [[ -z "$p" ]] && continue
      if [[ -n "$NPM_GLOBAL_LIST" ]] && grep -qF "$p" <<<"$NPM_GLOBAL_LIST"; then
        run_cmd "npm uninstall -g $p" npm uninstall -g "$p"
      fi
    done
  fi

  if [[ -n "$pip_pkgs" ]]; then
    IFS=',' read -ra pip_arr <<<"$pip_pkgs"
    for p in "${pip_arr[@]}"; do
      [[ -z "$p" ]] && continue
      if [[ -n "$PIPX_LIST" ]] && grep -qiF "$p" <<<"$PIPX_LIST"; then
        run_cmd "pipx uninstall $p" pipx uninstall "$p"
      elif [[ -n "$PIP_LIST" ]] && grep -qiF "$p" <<<"$PIP_LIST"; then
        if command -v pip3 >/dev/null 2>&1; then
          run_cmd "pip3 uninstall -y $p" pip3 uninstall -y "$p"
        else
          run_cmd "pip uninstall -y $p" pip uninstall -y "$p"
        fi
      fi
    done
  fi

  local dir_arr=()
  IFS=',' read -ra dir_arr <<<"$dirs"
  local d
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" || ! -e "$d" ]] && continue
    run_cmd "remover $d" rm -rf "$d"
  done

  local bin_arr=()
  IFS=',' read -ra bin_arr <<<"$bins"
  local b
  for b in "${bin_arr[@]}"; do
    [[ -z "$b" ]] && continue
    local path
    path="$(command -v "$b" 2>/dev/null)" || continue
    case "$path" in
      "$HOME"*|/usr/local/bin/*|/opt/*)
        run_cmd "remover binário $path" rm -f "$path"
        ;;
      *)
        warn "Binário '$b' em $path parece gerenciado pelo sistema (apt/dpkg) — não removido automaticamente. Use o gerenciador de pacotes se quiser removê-lo."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_ROOT"
  log "=== Início da execução (dry_run=$DRY_RUN scan_only=$SCAN_ONLY) ==="

  run_scan
  print_report

  if [[ "${#FOUND_EVIDENCE[@]}" -eq 0 || "$SCAN_ONLY" -eq 1 ]]; then
    exit 0
  fi

  local selected_raw
  if [[ "$HAS_WHIPTAIL" -eq 1 ]]; then
    selected_raw="$(select_tools_whiptail)" || { warn "Cancelado."; exit 0; }
    # whiptail devolve tags entre aspas duplas, separadas por espaço
    selected_raw="$(tr -d '"' <<<"$selected_raw")"
  else
    selected_raw="$(select_tools_plain)"
  fi

  read -ra SELECTED <<<"$selected_raw"
  if [[ "${#SELECTED[@]}" -eq 0 ]]; then
    warn "Nenhuma ferramenta selecionada. Nada será removido."
    exit 0
  fi

  echo
  info "Resumo do que será feito:"
  local id
  for id in "${SELECTED[@]}"; do
    echo
    printf '\033[1m%s (%s)\033[0m\n' "$(tool_display_name "$id")" "$id"
    printf '%s\n' "${FOUND_EVIDENCE[$id]}" | while IFS='|' read -r kind ref extra; do
      case "$kind" in
        bin)  echo "  - remover binário: $extra" ;;
        npm)  echo "  - npm uninstall -g $ref" ;;
        pip)  echo "  - pip uninstall -y $ref" ;;
        pipx) echo "  - pipx uninstall $ref" ;;
        path) echo "  - apagar diretório/arquivo: $ref ($extra)" ;;
      esac
    done
  done
  echo

  local do_backup="no"
  if [[ "$HAS_WHIPTAIL" -eq 1 ]]; then
    if whiptail --title "ai-cli-cleaner" --yesno "Deseja fazer backup (.tar.gz) desses dados antes de apagar?" 10 70; then
      do_backup="yes"
    fi
  else
    read -r -p "Deseja fazer backup (.tar.gz) desses dados antes de apagar? [S/n] " resp
    [[ "$resp" =~ ^([sS]|)$ ]] && do_backup="yes"
  fi

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    warn "Esta ação é DESTRUTIVA e, sem backup, IRREVERSÍVEL."
    read -r -p "Digite APAGAR para confirmar a remoção acima: " confirm
    if [[ "$confirm" != "APAGAR" ]]; then
      warn "Confirmação não corresponde a 'APAGAR'. Operação cancelada."
      exit 0
    fi
  fi

  for id in "${SELECTED[@]}"; do
    remove_tool "$id" "$do_backup"
  done

  echo
  ok "Concluído. Log completo em: $LOG_FILE"
  [[ "$do_backup" == "yes" ]] && ok "Backups em: $BACKUP_ROOT"
}

main
