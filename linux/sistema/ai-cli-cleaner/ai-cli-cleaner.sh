#!/usr/bin/env bash
#
# ai-cli-cleaner.sh — detecta CLIs de IA instaladas no sistema (Linux) e permite:
#   1) limpeza básica     — só cache/temporários (regenerável)
#   2) limpeza completa   — cache + sessões/histórico/dados (mantém instalado e logado)
#   3) desinstalação completa — desinstala o pacote e apaga absolutamente tudo
# de uma ou várias ferramentas detectadas. Também permite restaurar um backup
# feito por uma dessas operações.
#
# Documentação: docs/linux/sistema/ai-cli-cleaner.md
#
# Uso:
#   ./ai-cli-cleaner.sh                 fluxo interativo completo (pergunta o modo)
#   ./ai-cli-cleaner.sh --mode=basic    vai direto pra limpeza básica (só cache)
#   ./ai-cli-cleaner.sh --mode=full     vai direto pra limpeza completa (mantém logado)
#   ./ai-cli-cleaner.sh --mode=purge    vai direto pra desinstalação completa
#   ./ai-cli-cleaner.sh --restore       restaura um backup feito anteriormente
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
MANIFEST_NAME=".ai-cli-cleaner-manifest"
LABEL_NAME=".ai-cli-cleaner-label"

DRY_RUN=0
SCAN_ONLY=0
ASSUME_YES=0
RESTORE=0
MODE=""   # "basic" | "full" | "purge" — se vazio, pergunta interativamente

# id|Nome de exibição|binários(csv)|pacotes npm(csv)|pacotes pip/pipx(csv)|
#   dirs de cache/temp(csv)|dirs de dados/sessões(csv)|dirs de credenciais/config(csv)
#
# "cache" = seguro apagar sem perder nada (regenerado pela ferramenta). Removido
#           já na limpeza básica.
# "dados" = sessões, histórico, config de uso, plugins etc. — não é necessário pra
#           login nem para o binário funcionar, mas não é regenerado sozinho.
#           Removido na limpeza completa (junto com o cache), sem desinstalar
#           nem derrubar o login.
# "manter" = credenciais/login e o que for necessário para o binário continuar
#            funcionando. Só é apagado na desinstalação completa.
#
# Para a maioria das ferramentas abaixo só o campo "cache" foi auditado de fato
# neste sistema — "dados" fica vazio até alguém confirmar a estrutura real de
# arquivos daquela ferramenta (nesse caso, limpeza completa == limpeza básica
# para ela). "claude" foi auditado por completo.
TOOLS=(
  "claude|Claude Code (Anthropic)|claude|@anthropic-ai/claude-code||$HOME/.cache/claude,$HOME/.claude/cache,$HOME/.claude/paste-cache,$HOME/.claude/session-env,$HOME/.claude/shell-snapshots,$HOME/.claude/stats-cache.json,$HOME/.claude/gh-pr-status-cache.json,$HOME/.claude/mcp-needs-auth-cache.json,$HOME/.claude/.last-update-result.json,$HOME/.claude/.last-cleanup|$HOME/.claude/projects,$HOME/.claude/history.jsonl,$HOME/.claude/sessions,$HOME/.claude/plans,$HOME/.claude/daemon,$HOME/.claude/daemon.log,$HOME/.claude/jobs,$HOME/.claude/downloads,$HOME/.claude/file-history,$HOME/.claude/chrome,$HOME/.claude/ide,$HOME/.claude/backups,$HOME/.claude.json|$HOME/.claude/.credentials.json,$HOME/.claude/settings.json,$HOME/.claude/settings.local.json,$HOME/.claude/plugins,$HOME/.claude/hooks,$HOME/.claude/skills,$HOME/.local/share/claude,$HOME/.config/claude"
  "gemini|Gemini CLI (Google)|gemini|@google/gemini-cli||$HOME/.cache/gemini||$HOME/.gemini,$HOME/.config/gemini,$HOME/.local/share/gemini"
  "antigravity|Antigravity (Google)|antigravity|||$HOME/.cache/antigravity||$HOME/.antigravity,$HOME/.config/antigravity,$HOME/.config/Antigravity,$HOME/.local/share/antigravity"
  "kimi|Kimi CLI (Moonshot AI)|kimi|kimi-cli,@moonshot-ai/kimi-cli||$HOME/.cache/kimi||$HOME/.kimi,$HOME/.config/kimi"
  "codex|Codex CLI (OpenAI)|codex|@openai/codex||$HOME/.cache/codex||$HOME/.codex,$HOME/.config/codex"
  "copilot|GitHub Copilot CLI|copilot,gh-copilot|@githubnext/github-copilot-cli||||$HOME/.copilot,$HOME/.config/gh-copilot,$HOME/.config/github-copilot"
  "cursor-agent|Cursor CLI|cursor-agent|||$HOME/.cache/cursor-agent||$HOME/.cursor,$HOME/.config/Cursor,$HOME/.config/cursor-agent"
  "aider|Aider|aider||aider-chat|$HOME/.cache/aider,$HOME/.aider.tags.cache.v3||$HOME/.aider,$HOME/.aider.conf.yml,$HOME/.config/aider"
  "q|Amazon Q CLI|q||amazon-q-cli|||$HOME/.config/amazon-q,$HOME/.local/share/amazon-q"
  "qwen|Qwen Code CLI|qwen|@qwen-code/qwen-code||$HOME/.cache/qwen||$HOME/.qwen,$HOME/.config/qwen"
  "opencode|opencode|opencode||opencode-ai|||$HOME/.opencode,$HOME/.config/opencode,$HOME/.local/share/opencode"
  "goose|Goose (Block)|goose|||$HOME/.cache/goose||$HOME/.config/goose,$HOME/.local/share/goose"
  "ollama|Ollama|ollama|||$HOME/.ollama/models||$HOME/.ollama"
  "interpreter|Open Interpreter|interpreter||open-interpreter|$HOME/.cache/open-interpreter||$HOME/.interpreter,$HOME/.config/open-interpreter,$HOME/.local/share/open-interpreter"
  "llm|llm (Simon Willison)|llm||llm|||$HOME/.config/io.datasette.llm"
  "grok|Grok CLI (xAI)|grok|@xai/grok-cli||$HOME/.cache/grok||$HOME/.grok,$HOME/.config/grok"
  "deepseek|DeepSeek CLI|deepseek|deepseek-cli||$HOME/.cache/deepseek||$HOME/.deepseek,$HOME/.config/deepseek"
)

HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

NPM_GLOBAL_LIST=""
PIP_LIST=""
PIPX_LIST=""

# resultados da varredura
declare -A FOUND_EVIDENCE     # id -> linhas "kind|ref|extra"
declare -A FOUND_SIZE         # id -> tamanho total (cache+dados+manter)
declare -A FOUND_CACHE_SIZE   # id -> tamanho só do cache/temp ("-" se não achou nada)
declare -A FOUND_DATA_SIZE    # id -> tamanho só de dados/sessões ("-" se não achou nada)

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
ai-cli-cleaner.sh — detecta CLIs de IA instaladas e permite limpar (em três
níveis) ou desinstalar por completo, de uma ou várias ferramentas detectadas.
Também restaura backups feitos por essas operações.

Uso:
  ./ai-cli-cleaner.sh                 fluxo interativo completo
  ./ai-cli-cleaner.sh --mode=basic    limpeza básica — só cache/temporários
  ./ai-cli-cleaner.sh --mode=full     limpeza completa — cache + dados/sessões (mantém logado)
  ./ai-cli-cleaner.sh --mode=purge    desinstalação completa — remove absolutamente tudo
  ./ai-cli-cleaner.sh --restore       restaura um backup feito anteriormente
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
    --restore) RESTORE=1 ;;
    --mode=basic) MODE="basic" ;;
    --mode=full) MODE="full" ;;
    --mode=purge) MODE="purge" ;;
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
  local id="$1" bins="$2" npm_pkgs="$3" pip_pkgs="$4" cache_dirs="$5" data_dirs="$6" keep_dirs="$7"
  local evidence=()
  local cache_paths=() data_paths=() keep_paths=()

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
    fi
  done

  IFS=',' read -ra dir_arr <<<"$data_dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d" ]]; then
      evidence+=("data|$d|$(human_size "$d")")
      data_paths+=("$d")
    fi
  done

  IFS=',' read -ra dir_arr <<<"$keep_dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d" ]]; then
      evidence+=("keep|$d|$(human_size "$d")")
      keep_paths+=("$d")
    fi
  done

  if [[ "${#evidence[@]}" -gt 0 ]]; then
    FOUND_EVIDENCE["$id"]="$(printf '%s\n' "${evidence[@]}")"
    local all_paths=("${cache_paths[@]}" "${data_paths[@]}" "${keep_paths[@]}")
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
    if [[ "${#data_paths[@]}" -gt 0 ]]; then
      FOUND_DATA_SIZE["$id"]="$(du -ch "${data_paths[@]}" 2>/dev/null | tail -1 | cut -f1)"
    else
      FOUND_DATA_SIZE["$id"]="-"
    fi
  fi
}

run_scan() {
  info "Coletando listas de pacotes (npm/pip/pipx)..."
  collect_global_lists
  info "Varrendo o sistema em busca de CLIs de IA conhecidas..."
  local entry id display bins npm_pkgs pip_pkgs cache_dirs data_dirs keep_dirs
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r id display bins npm_pkgs pip_pkgs cache_dirs data_dirs keep_dirs <<<"$entry"
    scan_tool "$id" "$bins" "$npm_pkgs" "$pip_pkgs" "$cache_dirs" "$data_dirs" "$keep_dirs"
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
  # imprime bins/npm_pkgs/pip_pkgs/cache_dirs/data_dirs/keep_dirs (uma por linha) para um id
  local id="$1" entry
  for entry in "${TOOLS[@]}"; do
    IFS='|' read -r eid _ ebins enpm epip ecache edata ekeep <<<"$entry"
    if [[ "$eid" == "$id" ]]; then
      printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$ebins" "$enpm" "$epip" "$ecache" "$edata" "$ekeep"
      return
    fi
  done
}

# ids encontrados elegíveis para o modo atual
eligible_ids() {
  local mode="$1" id
  for id in "${!FOUND_EVIDENCE[@]}"; do
    case "$mode" in
      basic) [[ "${FOUND_CACHE_SIZE[$id]:--}" != "-" ]] && printf '%s\n' "$id" ;;
      full)  [[ "${FOUND_CACHE_SIZE[$id]:--}" != "-" || "${FOUND_DATA_SIZE[$id]:--}" != "-" ]] && printf '%s\n' "$id" ;;
      purge) printf '%s\n' "$id" ;;
    esac
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
  printf '\033[1m%-14s %-32s %-10s %-10s %-10s %s\033[0m\n' "ID" "FERRAMENTA" "TOTAL" "CACHE" "DADOS" "EVIDÊNCIAS"
  for id in "${!FOUND_EVIDENCE[@]}"; do
    local display size cache data count
    display="$(tool_display_name "$id")"
    size="${FOUND_SIZE[$id]}"
    cache="${FOUND_CACHE_SIZE[$id]}"
    data="${FOUND_DATA_SIZE[$id]}"
    count="$(printf '%s\n' "${FOUND_EVIDENCE[$id]}" | grep -c .)"
    printf '%-14s %-32s %-10s %-10s %-10s %s evidência(s)\n' "$id" "$display" "$size" "$cache" "$data" "$count"
  done
  echo
}

# ---------------------------------------------------------------------------
# Escolha do modo
# ---------------------------------------------------------------------------

choose_mode() {
  if [[ -n "$MODE" ]]; then
    printf '%s' "$MODE"
    return
  fi
  if [[ "$HAS_WHIPTAIL" -eq 1 ]]; then
    whiptail --title "ai-cli-cleaner" --menu \
      "O que você quer fazer?" 16 78 3 \
      "basic" "Limpeza básica — só cache/temporários (regenerável)" \
      "full"  "Limpeza completa — cache + dados/sessões (mantém instalado e logado)" \
      "purge" "Desinstalação completa — remove absolutamente tudo" \
      3>&1 1>&2 2>&3
  else
    echo "O que você quer fazer?" >&2
    echo "  1) Limpeza básica — só cache/temporários (regenerável)" >&2
    echo "  2) Limpeza completa — cache + dados/sessões (mantém instalado e logado)" >&2
    echo "  3) Desinstalação completa — remove absolutamente tudo" >&2
    local resp
    read -r -p "Escolha [1/2/3]: " resp
    case "$resp" in
      2) printf 'full' ;;
      3) printf 'purge' ;;
      *) printf 'basic' ;;
    esac
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
  echo "Ferramentas encontradas:" >&2
  local i=1 id
  for id in "${ids[@]}"; do
    printf '  %d) %s (%s) [%s]\n' "$i" "$(tool_display_name "$id")" "${FOUND_SIZE[$id]}" "$id" >&2
    i=$((i + 1))
  done
  echo >&2
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
# Execução de comandos / backup
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

# Empacota uma cópia fiel (mesma árvore de diretórios a partir de "/") dos
# caminhos passados, para que restore_flow() consiga devolver cada arquivo
# exatamente para onde estava. O manifesto (lista dos caminhos originais)
# fica dentro do próprio .tar.gz.
#
# Retorna 0 quando é seguro prosseguir com a remoção: ou o backup foi
# compactado com sucesso, ou não havia nada de fato para copiar (paths
# inexistentes — nada a perder). Retorna 1 quando existia algo a proteger e o
# backup não pôde ser garantido — quem chamar NÃO deve apagar nada nesse caso.
backup_paths() {
  local label="$1"
  shift
  local paths=("$@")
  local existing=()
  local p
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] && existing+=("$p")
  done
  [[ "${#existing[@]}" -eq 0 ]] && return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    for p in "${existing[@]}"; do
      warn "[DRY-RUN] backup de $p"
    done
    return 0
  fi

  local tmp_dir="$BACKUP_ROOT/.tmp-${label}-${TIMESTAMP}"
  local tar_path="$BACKUP_ROOT/${label}-${TIMESTAMP}.tar.gz"
  local manifest=()
  mkdir -p "$tmp_dir"
  for p in "${existing[@]}"; do
    if cp -a --parents "$p" "$tmp_dir" 2>>"$LOG_FILE"; then
      manifest+=("$p")
    else
      err "Não consegui copiar $p para o backup — veja $LOG_FILE"
    fi
  done

  if [[ "${#manifest[@]}" -ne "${#existing[@]}" ]]; then
    err "Backup de $label incompleto — abortando remoção por segurança (nada foi apagado)"
    rm -rf "$tmp_dir"
    return 1
  fi

  printf '%s\n' "${manifest[@]}" >"$tmp_dir/$MANIFEST_NAME"
  printf '%s\n' "$label" >"$tmp_dir/$LABEL_NAME"

  if tar -czf "$tar_path" -C "$tmp_dir" . 2>>"$LOG_FILE"; then
    rm -rf "$tmp_dir"
    ok "Backup de $label salvo em $tar_path"
    return 0
  else
    rm -f "$tar_path"
    err "Não foi possível compactar o backup de $label (arquivos ficaram em $tmp_dir) — abortando remoção por segurança"
    return 1
  fi
}

list_backups() {
  find "$BACKUP_ROOT" -maxdepth 1 -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2-
}

# ---------------------------------------------------------------------------
# Restauração de backup
# ---------------------------------------------------------------------------

# Restaura $src (cópia extraída do backup) de volta para $dest (caminho
# original). Se $dest já existir, faz antes um mini-backup do estado atual
# dele (pasta .ai-cli-cleaner/backups/.pre-restore-*) para nunca sobrescrever
# nada sem uma cópia de segurança — mesmo dados criados depois do backup
# original ficam preservados ali, só não voltam automaticamente.
restore_path() {
  local src="$1" dest="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "[DRY-RUN] restaurar $dest"
    return 0
  fi

  if [[ -e "$dest" ]]; then
    local pre_dir="$BACKUP_ROOT/.pre-restore-$TIMESTAMP"
    mkdir -p "$pre_dir"
    if cp -a --parents "$dest" "$pre_dir" 2>>"$LOG_FILE"; then
      warn "Estado atual de $dest salvo em $pre_dir antes de sobrescrever"
    else
      err "Não consegui preservar o estado atual de $dest — pulando restauração desse caminho por segurança"
      return 1
    fi
    rm -rf "$dest"
  fi

  mkdir -p "$(dirname "$dest")"
  if cp -a "$src" "$dest" 2>>"$LOG_FILE"; then
    ok "restaurado: $dest"
  else
    err "Falhou ao restaurar $dest (veja $LOG_FILE)"
  fi
}

restore_flow() {
  mapfile -t backups < <(list_backups)
  if [[ "${#backups[@]}" -eq 0 ]]; then
    warn "Nenhum backup encontrado em $BACKUP_ROOT."
    return
  fi

  echo "Backups disponíveis (mais recente primeiro):"
  local i=1 b
  for b in "${backups[@]}"; do
    printf '  %d) %s (%s)\n' "$i" "$(basename "$b")" "$(human_size "$b")"
    i=$((i + 1))
  done
  echo
  local choice
  read -r -p "Escolha o backup a restaurar (número, vazio para cancelar): " choice
  [[ -z "$choice" ]] && { warn "Cancelado."; return; }
  if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
    err "Escolha inválida."
    return
  fi
  local idx=$((choice - 1))
  if [[ "$idx" -lt 0 || "$idx" -ge "${#backups[@]}" ]]; then
    err "Escolha inválida."
    return
  fi
  local tar_path="${backups[$idx]}"

  local extract_dir="$BACKUP_ROOT/.restore-$TIMESTAMP"
  mkdir -p "$extract_dir"
  if ! tar -xzf "$tar_path" -C "$extract_dir" 2>>"$LOG_FILE"; then
    err "Falha ao extrair $tar_path (veja $LOG_FILE)"
    rm -rf "$extract_dir"
    return
  fi

  if [[ ! -f "$extract_dir/$MANIFEST_NAME" ]]; then
    err "Backup sem manifesto reconhecível — não sei quais caminhos restaurar."
    rm -rf "$extract_dir"
    return
  fi

  mapfile -t manifest <"$extract_dir/$MANIFEST_NAME"
  echo
  info "Este backup contém:"
  local m
  for m in "${manifest[@]}"; do
    echo "  - $m"
  done
  echo
  read -r -p "Restaurar esses caminhos para o sistema? Pode sobrescrever dados atuais. [s/N] " confirm
  if [[ ! "$confirm" =~ ^[sS]$ ]]; then
    warn "Cancelado."
    rm -rf "$extract_dir"
    return
  fi

  for m in "${manifest[@]}"; do
    local src="$extract_dir$m"
    if [[ ! -e "$src" ]]; then
      warn "Faltando no backup: $m"
      continue
    fi
    restore_path "$src" "$m"
  done

  rm -rf "$extract_dir"
  ok "Restauração concluída. Log completo em: $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Limpeza / remoção
# ---------------------------------------------------------------------------

# nível 1: só cache/temp, regenerável — não toca em dados, config, pacote ou binário
run_basic() {
  local id="$1" do_backup="$2"
  local fields cache_dirs
  mapfile -t fields < <(tool_fields "$id")
  cache_dirs="${fields[3]}"

  info "=== Limpeza básica: $(tool_display_name "$id") ==="

  local dir_arr=()
  IFS=',' read -ra dir_arr <<<"$cache_dirs"

  if [[ "$do_backup" == "yes" ]] && ! backup_paths "${id}-basic" "${dir_arr[@]}"; then
    err "Cancelando limpeza básica de $(tool_display_name "$id") — backup não pôde ser garantido."
    return 1
  fi

  local d
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" || ! -e "$d" ]] && continue
    run_cmd "remover cache $d" rm -rf "$d"
  done
}

# nível 2: cache + dados/sessões — mantém o pacote instalado e o login intacto
run_full() {
  local id="$1" do_backup="$2"
  local fields cache_dirs data_dirs
  mapfile -t fields < <(tool_fields "$id")
  cache_dirs="${fields[3]}"; data_dirs="${fields[4]}"

  info "=== Limpeza completa (mantém instalado e logado): $(tool_display_name "$id") ==="

  local all_dirs=() dir_arr=()
  IFS=',' read -ra dir_arr <<<"$cache_dirs"; all_dirs+=("${dir_arr[@]}")
  IFS=',' read -ra dir_arr <<<"$data_dirs"; all_dirs+=("${dir_arr[@]}")

  if [[ "$do_backup" == "yes" ]] && ! backup_paths "${id}-full" "${all_dirs[@]}"; then
    err "Cancelando limpeza completa de $(tool_display_name "$id") — backup não pôde ser garantido."
    return 1
  fi

  local d
  for d in "${all_dirs[@]}"; do
    [[ -z "$d" || ! -e "$d" ]] && continue
    run_cmd "remover $d" rm -rf "$d"
  done
}

# nível 3: desinstala pacote, apaga cache+dados+credenciais, remove binário se for seguro
run_purge() {
  local id="$1" do_backup="$2"
  local fields bins npm_pkgs pip_pkgs cache_dirs data_dirs keep_dirs
  mapfile -t fields < <(tool_fields "$id")
  bins="${fields[0]}"; npm_pkgs="${fields[1]}"; pip_pkgs="${fields[2]}"
  cache_dirs="${fields[3]}"; data_dirs="${fields[4]}"; keep_dirs="${fields[5]}"

  info "=== Desinstalação completa: $(tool_display_name "$id") ==="

  if [[ "$do_backup" == "yes" ]]; then
    local all_dirs=() dir_arr=()
    IFS=',' read -ra dir_arr <<<"$cache_dirs"; all_dirs+=("${dir_arr[@]}")
    IFS=',' read -ra dir_arr <<<"$data_dirs"; all_dirs+=("${dir_arr[@]}")
    IFS=',' read -ra dir_arr <<<"$keep_dirs"; all_dirs+=("${dir_arr[@]}")
    if ! backup_paths "${id}-purge" "${all_dirs[@]}"; then
      err "Cancelando desinstalação de $(tool_display_name "$id") — backup não pôde ser garantido."
      return 1
    fi
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
  IFS=',' read -ra dir_arr <<<"$cache_dirs,$data_dirs,$keep_dirs"
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
      case "$mode" in
        basic)
          [[ "$kind" == "cache" ]] && echo "  - apagar cache/temporários: $ref ($extra)"
          ;;
        full)
          case "$kind" in
            cache) echo "  - apagar cache/temporários: $ref ($extra)" ;;
            data)  echo "  - apagar dados/sessões: $ref ($extra)" ;;
          esac
          ;;
        purge)
          case "$kind" in
            bin)   echo "  - remover binário: $extra" ;;
            npm)   echo "  - npm uninstall -g $ref" ;;
            pip)   echo "  - pip uninstall -y $ref" ;;
            pipx)  echo "  - pipx uninstall $ref" ;;
            cache) echo "  - apagar cache/temporários: $ref ($extra)" ;;
            data)  echo "  - apagar dados/sessões: $ref ($extra)" ;;
            keep)  echo "  - apagar credenciais/config: $ref ($extra)" ;;
          esac
          ;;
      esac
    done
    if [[ "$mode" == "full" && "$id" == "claude" ]]; then
      warn "  atenção: inclui a pasta de memória entre sessões do Claude Code (~/.claude/projects/*/memory)."
    fi
  done
  echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_ROOT"
  log "=== Início da execução (dry_run=$DRY_RUN scan_only=$SCAN_ONLY mode=$MODE restore=$RESTORE) ==="

  if [[ "$RESTORE" -eq 1 ]]; then
    restore_flow
    exit 0
  fi

  run_scan
  print_report

  if [[ "${#FOUND_EVIDENCE[@]}" -eq 0 || "$SCAN_ONLY" -eq 1 ]]; then
    exit 0
  fi

  local mode
  mode="$(choose_mode)"
  if [[ "$mode" != "basic" && "$mode" != "full" && "$mode" != "purge" ]]; then
    warn "Cancelado."
    exit 0
  fi
  log "Modo escolhido: $mode"

  mapfile -t ELIGIBLE < <(eligible_ids "$mode")
  if [[ "${#ELIGIBLE[@]}" -eq 0 ]]; then
    warn "Nenhuma ferramenta elegível para o modo '$mode'."
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
  info "Backup automático (.tar.gz) será feito antes de qualquer remoção — restaure com --restore."

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    warn "Esta ação é DESTRUTIVA. Há backup automático, mas restaurar é manual (--restore)."
    read -r -p "Digite APAGAR para confirmar a operação acima: " confirm
    if [[ "$confirm" != "APAGAR" ]]; then
      warn "Confirmação não corresponde a 'APAGAR'. Operação cancelada."
      exit 0
    fi
  fi

  local id
  for id in "${SELECTED[@]}"; do
    case "$mode" in
      basic) run_basic "$id" "yes" ;;
      full)  run_full "$id" "yes" ;;
      purge) run_purge "$id" "yes" ;;
    esac
  done

  echo
  ok "Concluído. Log completo em: $LOG_FILE"
  ok "Backups em: $BACKUP_ROOT (restaure com --restore)"
}

main
