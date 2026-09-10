#!/usr/bin/env bash
#
# ai-cli-cleaner.sh — detecta CLIs de IA instaladas no sistema (Linux) e permite:
#   1) remoção completa (desinstala pacote + apaga config/cache/dados)
#   2) apagar só arquivos temporários/cache (mantém a ferramenta instalada)
# de uma ou várias ferramentas detectadas.
#
# Documentação: docs/linux/sistema/ai-cli-cleaner.md
#
# Uso:
#   ./ai-cli-cleaner.sh                 fluxo interativo completo (pergunta o modo)
#   ./ai-cli-cleaner.sh --mode=clean    vai direto pro modo "só cache/temporários"
#   ./ai-cli-cleaner.sh --mode=full     vai direto pro modo "remoção completa"
#   ./ai-cli-cleaner.sh --scan          só escaneia e mostra o relatório
#   ./ai-cli-cleaner.sh --dry-run       roda o fluxo todo sem alterar nada
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
MODE=""   # "full" | "clean" — se vazio, pergunta interativamente

# id|Nome de exibição|binários(csv)|pacotes npm(csv)|pacotes pip/pipx(csv)|dirs de cache/temp(csv)|dirs de config/dados(csv)
#
# "cache" = seguro apagar sem perder login/config (é regenerado pela ferramenta).
# "config" = contém credenciais/configuração/dados — só é apagado na remoção completa.
TOOLS=(
  "claude|Claude Code (Anthropic)|claude|@anthropic-ai/claude-code||$HOME/.cache/claude|$HOME/.claude,$HOME/.claude.json,$HOME/.config/claude,$HOME/.local/share/claude"
  "gemini|Gemini CLI (Google)|gemini|@google/gemini-cli||$HOME/.cache/gemini|$HOME/.gemini,$HOME/.config/gemini,$HOME/.local/share/gemini"
  "antigravity|Antigravity (Google)|antigravity|||$HOME/.cache/antigravity|$HOME/.antigravity,$HOME/.config/antigravity,$HOME/.config/Antigravity,$HOME/.local/share/antigravity"
  "kimi|Kimi CLI (Moonshot AI)|kimi|kimi-cli,@moonshot-ai/kimi-cli||$HOME/.cache/kimi|$HOME/.kimi,$HOME/.config/kimi"
  "codex|Codex CLI (OpenAI)|codex|@openai/codex||$HOME/.cache/codex|$HOME/.codex,$HOME/.config/codex"
  "copilot|GitHub Copilot CLI|copilot,gh-copilot|@githubnext/github-copilot-cli|||$HOME/.copilot,$HOME/.config/gh-copilot,$HOME/.config/github-copilot"
  "cursor-agent|Cursor CLI|cursor-agent|||$HOME/.cache/cursor-agent|$HOME/.cursor,$HOME/.config/Cursor,$HOME/.config/cursor-agent"
  "aider|Aider|aider||aider-chat|$HOME/.cache/aider,$HOME/.aider.tags.cache.v3|$HOME/.aider,$HOME/.aider.conf.yml,$HOME/.config/aider"
  "q|Amazon Q CLI|q||amazon-q-cli||$HOME/.config/amazon-q,$HOME/.local/share/amazon-q"
  "qwen|Qwen Code CLI|qwen|@qwen-code/qwen-code||$HOME/.cache/qwen|$HOME/.qwen,$HOME/.config/qwen"
  "opencode|opencode|opencode||opencode-ai||$HOME/.opencode,$HOME/.config/opencode,$HOME/.local/share/opencode"
  "goose|Goose (Block)|goose|||$HOME/.cache/goose|$HOME/.config/goose,$HOME/.local/share/goose"
  "ollama|Ollama|ollama|||$HOME/.ollama/models|$HOME/.ollama"
  "interpreter|Open Interpreter|interpreter||open-interpreter|$HOME/.cache/open-interpreter|$HOME/.interpreter,$HOME/.config/open-interpreter,$HOME/.local/share/open-interpreter"
  "llm|llm (Simon Willison)|llm||llm||$HOME/.config/io.datasette.llm"
  "grok|Grok CLI (xAI)|grok|@xai/grok-cli||$HOME/.cache/grok|$HOME/.grok,$HOME/.config/grok"
  "deepseek|DeepSeek CLI|deepseek|deepseek-cli||$HOME/.cache/deepseek|$HOME/.deepseek,$HOME/.config/deepseek"
)

HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

NPM_GLOBAL_LIST=""
PIP_LIST=""
PIPX_LIST=""

# resultados da varredura
declare -A FOUND_EVIDENCE     # id -> linhas "kind|ref|extra"
declare -A FOUND_SIZE         # id -> tamanho total (cache+config)
declare -A FOUND_CACHE_SIZE   # id -> tamanho só do cache/temp ("-" se não achou nada)

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
ai-cli-cleaner.sh — detecta CLIs de IA instaladas e permite remover tudo ou
só limpar cache/temporários, de uma ou várias ferramentas.

Uso:
  ./ai-cli-cleaner.sh                 fluxo interativo completo
  ./ai-cli-cleaner.sh --mode=clean    só apagar cache/temporários (mantém instalado)
  ./ai-cli-cleaner.sh --mode=full     remoção completa (desinstala + apaga tudo)
  ./ai-cli-cleaner.sh --scan          só escaneia e mostra o relatório, não altera nada
  ./ai-cli-cleaner.sh --dry-run       roda o fluxo todo mas só mostra o que faria
  ./ai-cli-cleaner.sh --yes           pula a confirmação por escrito (ainda pergunta y/n)
  ./ai-cli-cleaner.sh --help          mostra esta ajuda
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
    --mode=full) MODE="full" ;;
    --mode=clean) MODE="clean" ;;
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
  local id="$1" bins="$2" npm_pkgs="$3" pip_pkgs="$4" cache_dirs="$5" config_dirs="$6"
  local evidence=()
  local all_paths=() cache_paths=()

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
  IFS=',' read -ra dir_arr <<<"$cache_dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d" ]]; then
      evidence+=("cache|$d|$(human_size "$d")")
      cache_paths+=("$d")
      all_paths+=("$d")
    fi
  done

  IFS=',' read -ra dir_arr <<<"$config_dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d" ]]; then
      evidence+=("cfg|$d|$(human_size "$d")")
      all_paths+=("$d")
    fi
  done

  if [[ "${#evidence[@]}" -gt 0 ]]; then
    FOUND_EVIDENCE["$id"]="$(printf '%s\n' "${evidence[@]}")"
    if [[ "${#all_paths[@]}" -gt 0 ]]; then
      FOUND_SIZE["$id"]="$(du -ch "${all_paths[@]}" 2>/dev/null | tail -1 | cut -f1)"
    else
      FOUND_SIZE["$id"]="-"
    fi
    if [[ "${#cache_paths[@]}" -gt 0 ]]; then
      FOUND_CACHE_SIZE["$id"]="$(du -ch "${cache_paths[@]}" 2>/dev/null | tail -1 | cut -f1)"
    else
      FOUND_CACHE_SIZE["$id"]="-"
    fi
  fi
}

run_scan() {
  info "Coletando listas de pacotes (npm/pip/pipx)..."
  collect_global_lists
  info "Varrendo o sistema em busca de CLIs de IA conhecidas..."
  local entry id display bins npm_pkgs pip_pkgs cache_dirs config_dirs
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r id display bins npm_pkgs pip_pkgs cache_dirs config_dirs <<<"$entry"
    scan_tool "$id" "$bins" "$npm_pkgs" "$pip_pkgs" "$cache_dirs" "$config_dirs"
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
  # imprime bins/npm_pkgs/pip_pkgs/cache_dirs/config_dirs (uma por linha) para um id
  local id="$1" entry
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r eid _ ebins enpm epip ecache econfig <<<"$entry"
    if [[ "$eid" == "$id" ]]; then
      printf '%s\n%s\n%s\n%s\n%s\n' "$ebins" "$enpm" "$epip" "$ecache" "$econfig"
      return
    fi
  done
}

# ids encontrados elegíveis para o modo atual: "full" = todos; "clean" = só quem tem cache
eligible_ids() {
  local mode="$1" id
  for id in "${!FOUND_EVIDENCE[@]}"; do
    if [[ "$mode" == "clean" ]]; then
      [[ "${FOUND_CACHE_SIZE[$id]:--}" != "-" ]] && printf '%s\n' "$id"
    else
      printf '%s\n' "$id"
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
  printf '\033[1m%-14s %-32s %-10s %-10s %s\033[0m\n' "ID" "FERRAMENTA" "TOTAL" "CACHE" "EVIDÊNCIAS"
  for id in "${!FOUND_EVIDENCE[@]}"; do
    local display size cache count
    display="$(tool_display_name "$id")"
    size="${FOUND_SIZE[$id]}"
    cache="${FOUND_CACHE_SIZE[$id]}"
    count="$(printf '%s\n' "${FOUND_EVIDENCE[$id]}" | grep -c .)"
    printf '%-14s %-32s %-10s %-10s %s evidência(s)\n' "$id" "$display" "$size" "$cache" "$count"
  done
  echo
}

# ---------------------------------------------------------------------------
# Escolha do modo (full / clean)
# ---------------------------------------------------------------------------

choose_mode() {
  if [[ -n "$MODE" ]]; then
    printf '%s' "$MODE"
    return
  fi
  if [[ "$HAS_WHIPTAIL" -eq 1 ]]; then
    whiptail --title "ai-cli-cleaner" --menu \
      "O que você quer fazer?" 14 78 2 \
      "clean" "Apagar só cache/temporários (mantém a ferramenta instalada)" \
      "full"  "Remoção completa (desinstala o pacote e apaga tudo)" \
      3>&1 1>&2 2>&3
  else
    echo "O que você quer fazer?" >&2
    echo "  1) Apagar só cache/temporários (mantém a ferramenta instalada)" >&2
    echo "  2) Remoção completa (desinstala o pacote e apaga tudo)" >&2
    local resp
    read -r -p "Escolha [1/2]: " resp
    [[ "$resp" == "2" ]] && printf 'full' || printf 'clean'
  fi
}

# ---------------------------------------------------------------------------
# Seleção (whiptail ou fallback em texto puro)
# ---------------------------------------------------------------------------

select_tools_whiptail() {
  # $@ = ids elegíveis
  local args=(--title "ai-cli-cleaner" --checklist \
    "Selecione (ESPAÇO) uma ou mais ferramentas e confirme com TAB/ENTER:" \
    20 78 10)
  local id
  for id in "$@"; do
    local display size
    display="$(tool_display_name "$id")"
    size="${FOUND_SIZE[$id]}"
    args+=("$id" "$display ($size)" OFF)
  done
  whiptail "${args[@]}" 3>&1 1>&2 2>&3
}

select_tools_plain() {
  # $@ = ids elegíveis
  local ids=("$@")
  echo "Ferramentas encontradas:"
  local i=1 id
  for id in "${ids[@]}"; do
    printf '  %d) %s (%s) [%s]\n' "$i" "$(tool_display_name "$id")" "${FOUND_SIZE[$id]}" "$id"
    i=$((i + 1))
  done
  echo
  read -r -p "Digite os números a processar, separados por espaço (ou 'todos', vazio para cancelar): " choice
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
  local label="$1"
  shift
  local paths=("$@")
  [[ "${#paths[@]}" -eq 0 ]] && return
  local tmp_dir="$BACKUP_ROOT/${label}-${TIMESTAMP}"
  local tar_path="$BACKUP_ROOT/${label}-${TIMESTAMP}.tar.gz"
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
  if tar -czf "$tar_path" -C "$BACKUP_ROOT" "${label}-${TIMESTAMP}" 2>>"$LOG_FILE"; then
    rm -rf "$tmp_dir"
    ok "Backup de $label salvo em $tar_path"
  else
    warn "Não foi possível compactar o backup de $label — arquivos ficaram em $tmp_dir"
  fi
}

# modo "clean": só apaga os dirs de cache/temp, não toca em pacote/config/binário
clean_tool_cache() {
  local id="$1" do_backup="$2"
  local fields cache_dirs
  mapfile -t fields < <(tool_fields "$id")
  cache_dirs="${fields[3]}"

  info "=== Limpando cache/temporários: $(tool_display_name "$id") ==="

  local dir_arr=()
  IFS=',' read -ra dir_arr <<<"$cache_dirs"

  if [[ "$do_backup" == "yes" ]]; then
    backup_paths "${id}-clean" "${dir_arr[@]}"
  fi

  local d
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" || ! -e "$d" ]] && continue
    run_cmd "remover cache $d" rm -rf "$d"
  done
}

# modo "full": desinstala pacote, apaga cache+config, remove binário se for seguro
uninstall_tool_full() {
  local id="$1" do_backup="$2"
  local fields bins npm_pkgs pip_pkgs cache_dirs config_dirs
  mapfile -t fields < <(tool_fields "$id")
  bins="${fields[0]}"; npm_pkgs="${fields[1]}"; pip_pkgs="${fields[2]}"
  cache_dirs="${fields[3]}"; config_dirs="${fields[4]}"

  info "=== Removendo por completo: $(tool_display_name "$id") ==="

  if [[ "$do_backup" == "yes" ]]; then
    local all_dirs=() dir_arr=()
    IFS=',' read -ra dir_arr <<<"$cache_dirs"; all_dirs+=("${dir_arr[@]}")
    IFS=',' read -ra dir_arr <<<"$config_dirs"; all_dirs+=("${dir_arr[@]}")
    backup_paths "${id}-full" "${all_dirs[@]}"
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
  IFS=',' read -ra dir_arr <<<"$cache_dirs,$config_dirs"
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
# Resumo antes da confirmação
# ---------------------------------------------------------------------------

print_summary() {
  local mode="$1"
  shift
  local ids=("$@")
  local id
  info "Resumo do que será feito (modo: $mode):"
  for id in "${ids[@]}"; do
    echo
    printf '\033[1m%s (%s)\033[0m\n' "$(tool_display_name "$id")" "$id"
    printf '%s\n' "${FOUND_EVIDENCE[$id]}" | while IFS='|' read -r kind ref extra; do
      if [[ "$mode" == "clean" ]]; then
        [[ "$kind" == "cache" ]] && echo "  - apagar cache/temporários: $ref ($extra)"
        continue
      fi
      case "$kind" in
        bin)   echo "  - remover binário: $extra" ;;
        npm)   echo "  - npm uninstall -g $ref" ;;
        pip)   echo "  - pip uninstall -y $ref" ;;
        pipx)  echo "  - pipx uninstall $ref" ;;
        cache) echo "  - apagar cache/temporários: $ref ($extra)" ;;
        cfg)   echo "  - apagar config/dados: $ref ($extra)" ;;
      esac
    done
  done
  echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_ROOT"
  log "=== Início da execução (dry_run=$DRY_RUN scan_only=$SCAN_ONLY mode=$MODE) ==="

  run_scan
  print_report

  if [[ "${#FOUND_EVIDENCE[@]}" -eq 0 || "$SCAN_ONLY" -eq 1 ]]; then
    exit 0
  fi

  local mode
  mode="$(choose_mode)"
  if [[ "$mode" != "full" && "$mode" != "clean" ]]; then
    warn "Cancelado."
    exit 0
  fi
  log "Modo escolhido: $mode"

  mapfile -t ELIGIBLE < <(eligible_ids "$mode")
  if [[ "${#ELIGIBLE[@]}" -eq 0 ]]; then
    warn "Nenhuma ferramenta elegível para o modo '$mode' (ex.: nenhum cache/temporário encontrado)."
    exit 0
  fi

  local selected_raw
  if [[ "$HAS_WHIPTAIL" -eq 1 ]]; then
    selected_raw="$(select_tools_whiptail "${ELIGIBLE[@]}")" || { warn "Cancelado."; exit 0; }
    selected_raw="$(tr -d '"' <<<"$selected_raw")"
  else
    selected_raw="$(select_tools_plain "${ELIGIBLE[@]}")"
  fi

  read -ra SELECTED <<<"$selected_raw"
  if [[ "${#SELECTED[@]}" -eq 0 ]]; then
    warn "Nenhuma ferramenta selecionada. Nada será feito."
    exit 0
  fi

  echo
  print_summary "$mode" "${SELECTED[@]}"

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
    read -r -p "Digite APAGAR para confirmar a operação acima: " confirm
    if [[ "$confirm" != "APAGAR" ]]; then
      warn "Confirmação não corresponde a 'APAGAR'. Operação cancelada."
      exit 0
    fi
  fi

  local id
  for id in "${SELECTED[@]}"; do
    if [[ "$mode" == "clean" ]]; then
      clean_tool_cache "$id" "$do_backup"
    else
      uninstall_tool_full "$id" "$do_backup"
    fi
  done

  echo
  ok "Concluído. Log completo em: $LOG_FILE"
  [[ "$do_backup" == "yes" ]] && ok "Backups em: $BACKUP_ROOT"
}

main
