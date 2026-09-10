#!/usr/bin/env bash
#
# ai-cli-uninstaller.sh — detecta CLIs de IA instaladas no sistema (Linux) e
# deixa escolher, item por item (cache, dados/sessões, credenciais/config,
# pacote npm/pip/pipx, binário), de qualquer combinação de ferramentas, o que
# apagar ou desinstalar. Mostra o tamanho de cada item e o total que será
# liberado com a seleção atual. Também restaura um backup feito anteriormente
# (compatível com os backups do ai-cli-cleaner.sh — mesmo formato/pasta).
#
# TUI: usa gum (https://github.com/charmbracelet/gum) se estiver instalado,
# com fallback pra whiptail e depois pra menu numerado em texto puro — roda
# em qualquer máquina mesmo sem nenhum dos dois instalados. Instalar o gum
# (não precisa de root): baixar o binário estático da release em
# github.com/charmbracelet/gum/releases e colocar em ~/.local/bin/gum.
#
# Documentação: docs/linux/sistema/ai-cli-uninstaller.md
#
# Uso:
#   ./ai-cli-uninstaller.sh             fluxo interativo (varre, lista itens, deixa escolher)
#   ./ai-cli-uninstaller.sh --restore   restaura um backup feito anteriormente
#   ./ai-cli-uninstaller.sh --scan      só escaneia e mostra o relatório de itens
#   ./ai-cli-uninstaller.sh --dry-run   roda o fluxo todo sem alterar nada
#   ./ai-cli-uninstaller.sh --yes       pula a confirmação por escrito (ainda pede o "APAGAR")
#   ./ai-cli-uninstaller.sh --help

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuração / estado global
# ---------------------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
STATE_DIR="$HOME/.ai-cli-cleaner"
LOG_DIR="$STATE_DIR/logs"
BACKUP_ROOT="$STATE_DIR/backups"
LOG_FILE="$LOG_DIR/ai-cli-uninstaller-$TIMESTAMP.log"
MANIFEST_NAME=".ai-cli-cleaner-manifest"
LABEL_NAME=".ai-cli-cleaner-label"

DRY_RUN=0
SCAN_ONLY=0
ASSUME_YES=0
RESTORE=0

# id|Nome de exibição|binários(csv)|pacotes npm(csv)|pacotes pip/pipx(csv)|
#   dirs de cache/temp(csv)|dirs de dados/sessões(csv)|dirs de credenciais/config(csv)
#
# "cache" = seguro apagar sem perder nada (regenerado pela ferramenta).
# "dados" = sessões, histórico, config de uso etc. — não é necessário pra login
#           nem para o binário funcionar, mas não é regenerado sozinho.
# "manter" = credenciais/login, config de plugins/hooks/conectores e o que for
#            necessário para o binário continuar funcionando.
#
# Cada diretório vira um item selecionável independente na TUI — a divisão em
# três categorias aqui é só o que orienta o rótulo/risco mostrado por item.
#
# Para a maioria das ferramentas abaixo só o campo "cache" foi auditado de fato
# neste sistema — "dados" fica vazio até alguém confirmar a estrutura real de
# arquivos daquela ferramenta. "claude" foi auditado por completo.
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

HAS_GUM=0
command -v gum >/dev/null 2>&1 && HAS_GUM=1

HAS_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && HAS_WHIPTAIL=1

NPM_GLOBAL_LIST=""
PIP_LIST=""
PIPX_LIST=""

declare -A FOUND_EVIDENCE   # id -> linhas "kind|ref|extra"

# lista plana de itens selecionáveis, construída por build_item_list()
ITEM_TOOL=()
ITEM_KIND=()
ITEM_REF=()
ITEM_EXTRA=()
ITEM_BYTES=()

# ---------------------------------------------------------------------------
# Helpers de log / saída
# ---------------------------------------------------------------------------

log() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
}

info() {
  if [[ "$HAS_GUM" -eq 1 ]]; then gum style --foreground 39 --bold "▸ $1"
  else printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; fi
  log "INFO: $1"
}
ok() {
  if [[ "$HAS_GUM" -eq 1 ]]; then gum style --foreground 42 --bold "✓ $1"
  else printf '\033[1;32m[ OK ]\033[0m %s\n' "$1"; fi
  log "OK: $1"
}
warn() {
  if [[ "$HAS_GUM" -eq 1 ]]; then gum style --foreground 214 --bold "⚠ $1"
  else printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; fi
  log "WARN: $1"
}
err() {
  if [[ "$HAS_GUM" -eq 1 ]]; then gum style --foreground 196 --bold "✗ $1" >&2
  else printf '\033[1;31m[ERRO]\033[0m %s\n' "$1" >&2; fi
  log "ERRO: $1"
}

banner() {
  [[ "$HAS_GUM" -eq 1 ]] || return 0
  gum style --border rounded --padding "0 2" --margin "1 0" \
    --border-foreground 212 --foreground 212 --bold \
    "ai-cli-uninstaller"
}

usage() {
  cat <<'EOF'
ai-cli-uninstaller.sh — detecta CLIs de IA instaladas e deixa escolher, item
por item (cache, dados/sessões, credenciais/config, pacote, binário), de
qualquer combinação de ferramentas, o que apagar ou desinstalar. Mostra o
tamanho de cada item e o total a liberar. Restaura backups (mesmo formato do
ai-cli-cleaner.sh).

TUI: gum se instalado, senão whiptail, senão menu numerado em texto puro.

Uso:
  ./ai-cli-uninstaller.sh             fluxo interativo completo
  ./ai-cli-uninstaller.sh --restore   restaura um backup feito anteriormente
  ./ai-cli-uninstaller.sh --scan      só escaneia e mostra o relatório de itens
  ./ai-cli-uninstaller.sh --dry-run   roda o fluxo todo mas só mostra o que faria
  ./ai-cli-uninstaller.sh --yes       pula a confirmação por escrito (ainda pede o "APAGAR")
  ./ai-cli-uninstaller.sh --help      mostra esta ajuda
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
# Tamanhos
# ---------------------------------------------------------------------------

human_size() {
  local path="$1"
  du -sh "$path" 2>/dev/null | cut -f1
}

bytes_of() {
  # du -sk (uso real em disco, blocos de 1K) em vez de -sb (tamanho aparente
  # do conteúdo) — precisa bater com o mesmo critério de human_size() (du -sh),
  # senão o total exibido subestima o espaço realmente liberado.
  local path="$1" n
  n="$(du -sk "$path" 2>/dev/null | cut -f1)"
  [[ -z "$n" ]] && n=0
  printf '%s' "$((n * 1024))"
}

human_from_bytes() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B --format='%.1f' "$bytes" 2>/dev/null && return
  fi
  awk -v b="$bytes" 'BEGIN {
    split("B K M G T", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f%s\n", b, u[i]
  }'
}

kind_label() {
  case "$1" in
    bin)   printf 'binário' ;;
    npm)   printf 'pacote npm' ;;
    pip)   printf 'pacote pip' ;;
    pipx)  printf 'pacote pipx' ;;
    cache) printf 'cache/temporários' ;;
    data)  printf 'dados/sessões' ;;
    keep)  printf 'credenciais/config' ;;
  esac
}

# Caminho/tamanho a exibir para o item $1 (índice em ITEM_*). Para "bin", o
# caminho de verdade fica em ITEM_EXTRA (ITEM_REF é só o nome do comando) —
# nos demais tipos é o contrário: ITEM_REF é o caminho/pacote e ITEM_EXTRA é
# o tamanho (ou vazio, pra npm/pip/pipx).
item_display_path() {
  local idx="$1"
  if [[ "${ITEM_KIND[$idx]}" == "bin" ]]; then
    printf '%s' "${ITEM_EXTRA[$idx]}"
  else
    printf '%s' "${ITEM_REF[$idx]}"
  fi
}

item_display_size() {
  local idx="$1"
  case "${ITEM_KIND[$idx]}" in
    cache|data|keep) printf '%s' "${ITEM_EXTRA[$idx]:--}" ;;
    *) printf '%s' "-" ;;
  esac
}

# ---------------------------------------------------------------------------
# Detecção
# ---------------------------------------------------------------------------

scan_tool() {
  local id="$1" bins="$2" npm_pkgs="$3" pip_pkgs="$4" cache_dirs="$5" data_dirs="$6" keep_dirs="$7"
  local evidence=()

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
    [[ -e "$d" ]] && evidence+=("cache|$d|$(human_size "$d")")
  done

  IFS=',' read -ra dir_arr <<<"$data_dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    [[ -e "$d" ]] && evidence+=("data|$d|$(human_size "$d")")
  done

  IFS=',' read -ra dir_arr <<<"$keep_dirs"
  for d in "${dir_arr[@]}"; do
    [[ -z "$d" ]] && continue
    [[ -e "$d" ]] && evidence+=("keep|$d|$(human_size "$d")")
  done

  [[ "${#evidence[@]}" -gt 0 ]] && FOUND_EVIDENCE["$id"]="$(printf '%s\n' "${evidence[@]}")"
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

# ---------------------------------------------------------------------------
# Lista plana de itens (um por linha de evidência, de todas as ferramentas)
# ---------------------------------------------------------------------------

build_item_list() {
  local id
  for id in $(printf '%s\n' "${!FOUND_EVIDENCE[@]}" | sort); do
    local kind ref extra bytes
    while IFS='|' read -r kind ref extra; do
      [[ -z "$kind" ]] && continue
      bytes=0
      case "$kind" in
        cache|data|keep) bytes="$(bytes_of "$ref")" ;;
      esac
      ITEM_TOOL+=("$id")
      ITEM_KIND+=("$kind")
      ITEM_REF+=("$ref")
      ITEM_EXTRA+=("$extra")
      ITEM_BYTES+=("$bytes")
    done <<<"${FOUND_EVIDENCE[$id]}"
  done
}

print_items_report() {
  if [[ "${#ITEM_TOOL[@]}" -eq 0 ]]; then
    ok "Nenhum rastro de CLI de IA conhecida foi encontrado neste sistema."
    return
  fi
  local i total=0
  for i in "${!ITEM_TOOL[@]}"; do
    total=$((total + ITEM_BYTES[i]))
  done

  if [[ "$HAS_GUM" -eq 1 ]]; then
    {
      for i in "${!ITEM_TOOL[@]}"; do
        printf '%d\t%s\t%s\t%s\t%s\n' \
          "$((i + 1))" \
          "$(tool_display_name "${ITEM_TOOL[$i]}")" \
          "$(kind_label "${ITEM_KIND[$i]}")" \
          "$(item_display_path "$i")" \
          "$(item_display_size "$i")"
      done
    } | gum table -s $'\t' -c "#,Ferramenta,Tipo,Caminho,Tamanho" --print
  else
    echo
    local last_tool=""
    for i in "${!ITEM_TOOL[@]}"; do
      if [[ "${ITEM_TOOL[$i]}" != "$last_tool" ]]; then
        last_tool="${ITEM_TOOL[$i]}"
        echo
        printf '\033[1m%s (%s)\033[0m\n' "$(tool_display_name "$last_tool")" "$last_tool"
      fi
      printf '  [%3d] %-20s %-60s %10s\n' "$((i + 1))" "$(kind_label "${ITEM_KIND[$i]}")" "$(item_display_path "$i")" "$(item_display_size "$i")"
    done
    echo
  fi

  info "Consumo total detectado: $(human_from_bytes "$total")"
  echo
}

# ---------------------------------------------------------------------------
# Seleção (gum, com fallback pra whiptail e depois texto puro) — itens, não
# ferramentas
# ---------------------------------------------------------------------------

# Cada opção é prefixada com "[NNN]" — depois de escolhido, é assim que
# reconstruímos o índice (ver parse_gum_choice_indices). O gum devolve o
# texto exato das opções selecionadas, uma por linha, via stdout.
select_items_gum() {
  local i options=() height
  for i in "${!ITEM_TOOL[@]}"; do
    options+=("$(printf '[%3d] %s · %s · %s (%s)' \
      "$((i + 1))" \
      "$(tool_display_name "${ITEM_TOOL[$i]}")" \
      "$(kind_label "${ITEM_KIND[$i]}")" \
      "$(item_display_path "$i")" "$(item_display_size "$i")")")
  done
  height=$(( ${#options[@]} < 15 ? ${#options[@]} + 1 : 15 ))
  printf '%s\n' "${options[@]}" | gum choose --no-limit --height="$height" \
    --header="Selecione (X) os itens a apagar/desinstalar e confirme com ENTER:" \
    --cursor.foreground=212 --selected.foreground=212 --header.foreground=99
}

# Extrai o número de dentro de "[NNN] ..." de cada linha selecionada.
parse_gum_choice_indices() {
  local line
  while IFS= read -r line; do
    [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\] ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done
}

select_items_whiptail() {
  local args=(--title "ai-cli-uninstaller" --checklist \
    "Selecione (ESPAÇO) os itens que deseja apagar/desinstalar e confirme com TAB/ENTER:" \
    24 100 16)
  local i label
  for i in "${!ITEM_TOOL[@]}"; do
    label="$(tool_display_name "${ITEM_TOOL[$i]}") · $(kind_label "${ITEM_KIND[$i]}") · $(item_display_path "$i") ($(item_display_size "$i"))"
    args+=("$((i + 1))" "$label" OFF)
  done
  whiptail "${args[@]}" 3>&1 1>&2 2>&3
}

select_items_plain() {
  read -r -p "Digite os números dos itens a processar, separados por espaço (ou 'todos', vazio para cancelar): " choice
  [[ -z "$choice" ]] && return
  local selected=()
  if [[ "$choice" == "todos" ]]; then
    local i
    for i in "${!ITEM_TOOL[@]}"; do selected+=("$((i + 1))"); done
  else
    local n
    for n in $choice; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      if [[ "$n" -ge 1 && "$n" -le "${#ITEM_TOOL[@]}" ]]; then
        selected+=("$n")
      fi
    done
  fi
  # numa única linha (IFS padrão = espaço) — quem chama lê com
  # `read -ra ARR <<<"$saida"`, que só pega a primeira linha.
  printf '%s\n' "${selected[*]}"
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
# exatamente para onde estava. Mesmo formato usado pelo ai-cli-cleaner.sh —
# os backups são intercambiáveis entre os dois scripts.
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

  local idx=-1 i=1 b

  if [[ "$HAS_GUM" -eq 1 ]]; then
    local options=()
    for b in "${backups[@]}"; do
      options+=("$(printf '[%3d] %s (%s)' "$i" "$(basename "$b")" "$(human_size "$b")")")
      i=$((i + 1))
    done
    local picked
    picked="$(printf '%s\n' "${options[@]}" | gum choose --limit=1 \
      --header="Escolha o backup a restaurar:" \
      --cursor.foreground=212 --selected.foreground=212 --header.foreground=99)"
    if [[ -z "$picked" ]]; then
      warn "Cancelado."
      return
    fi
    [[ "$picked" =~ ^\[[[:space:]]*([0-9]+)\] ]] && idx=$((BASH_REMATCH[1] - 1))
  else
    echo "Backups disponíveis (mais recente primeiro):"
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
    idx=$((choice - 1))
  fi

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
  local proceed=1
  if [[ "$HAS_GUM" -eq 1 ]]; then
    gum confirm "Restaurar esses caminhos para o sistema? Pode sobrescrever dados atuais." || proceed=0
  else
    local confirm
    read -r -p "Restaurar esses caminhos para o sistema? Pode sobrescrever dados atuais. [s/N] " confirm
    [[ "$confirm" =~ ^[sS]$ ]] || proceed=0
  fi
  if [[ "$proceed" -eq 0 ]]; then
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
# Resumo da seleção
# ---------------------------------------------------------------------------

selection_total_bytes() {
  local indices=("$@") i idx total=0
  for i in "${indices[@]}"; do
    idx=$((i - 1))
    total=$((total + ITEM_BYTES[idx]))
  done
  printf '%s' "$total"
}

print_selection_summary() {
  local indices=("$@") i idx
  info "Itens selecionados:"
  for i in "${indices[@]}"; do
    idx=$((i - 1))
    printf '  - %s · %s: %s (%s)\n' \
      "$(tool_display_name "${ITEM_TOOL[$idx]}")" \
      "$(kind_label "${ITEM_KIND[$idx]}")" \
      "$(item_display_path "$idx")" "$(item_display_size "$idx")"
    if [[ "${ITEM_TOOL[$idx]}" == "claude" && "${ITEM_REF[$idx]}" == *"/projects" ]]; then
      warn "    atenção: inclui a pasta de memória entre sessões do Claude Code (subpasta memory/)."
    fi
  done
  echo
  ok "Espaço estimado a liberar: $(human_from_bytes "$(selection_total_bytes "${indices[@]}")")"
}

# ---------------------------------------------------------------------------
# Execução: apaga/desinstala os itens selecionados
# ---------------------------------------------------------------------------

run_delete_items() {
  local indices=("$@")
  local fs_paths=() npm_pkgs=() pip_items=() pipx_items=() bin_paths=()
  local i idx kind

  for i in "${indices[@]}"; do
    idx=$((i - 1))
    kind="${ITEM_KIND[$idx]}"
    case "$kind" in
      cache|data|keep) fs_paths+=("${ITEM_REF[$idx]}") ;;
      npm)  npm_pkgs+=("${ITEM_REF[$idx]}") ;;
      pip)  pip_items+=("${ITEM_REF[$idx]}") ;;
      pipx) pipx_items+=("${ITEM_REF[$idx]}") ;;
      bin)  bin_paths+=("${ITEM_EXTRA[$idx]}") ;;
    esac
  done

  if ! backup_paths "custom-${TIMESTAMP}" "${fs_paths[@]}"; then
    err "Cancelando toda a operação — backup não pôde ser garantido. Nada foi apagado."
    return 1
  fi

  local p
  for p in "${npm_pkgs[@]}"; do
    run_cmd "npm uninstall -g $p" npm uninstall -g "$p"
  done
  for p in "${pipx_items[@]}"; do
    run_cmd "pipx uninstall $p" pipx uninstall "$p"
  done
  for p in "${pip_items[@]}"; do
    if command -v pip3 >/dev/null 2>&1; then
      run_cmd "pip3 uninstall -y $p" pip3 uninstall -y "$p"
    else
      run_cmd "pip uninstall -y $p" pip uninstall -y "$p"
    fi
  done

  local d
  for d in "${fs_paths[@]}"; do
    [[ -e "$d" ]] || continue
    run_cmd "remover $d" rm -rf "$d"
  done

  local path
  for path in "${bin_paths[@]}"; do
    [[ -e "$path" ]] || continue
    case "$path" in
      "$HOME"*|/usr/local/bin/*|/opt/*)
        run_cmd "remover binário $path" rm -f "$path"
        ;;
      *)
        warn "Binário em $path parece gerenciado pelo sistema (apt/dpkg) — não removido automaticamente. Use o gerenciador de pacotes se quiser removê-lo."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_ROOT"
  log "=== Início da execução (dry_run=$DRY_RUN scan_only=$SCAN_ONLY restore=$RESTORE) ==="

  banner

  if [[ "$RESTORE" -eq 1 ]]; then
    restore_flow
    exit 0
  fi

  run_scan
  build_item_list
  print_items_report

  if [[ "${#ITEM_TOOL[@]}" -eq 0 || "$SCAN_ONLY" -eq 1 ]]; then
    exit 0
  fi

  local SELECTED=()
  if [[ "$HAS_GUM" -eq 1 ]]; then
    mapfile -t SELECTED < <(select_items_gum | parse_gum_choice_indices)
  elif [[ "$HAS_WHIPTAIL" -eq 1 ]]; then
    local selected_raw
    selected_raw="$(select_items_whiptail)" || { warn "Cancelado."; exit 0; }
    selected_raw="$(tr -d '"' <<<"$selected_raw")"
    read -ra SELECTED <<<"$selected_raw"
  else
    local selected_raw
    selected_raw="$(select_items_plain)"
    read -ra SELECTED <<<"$selected_raw"
  fi

  if [[ "${#SELECTED[@]}" -eq 0 ]]; then
    warn "Nenhum item selecionado. Nada será feito."
    exit 0
  fi

  echo
  print_selection_summary "${SELECTED[@]}"
  info "Backup automático (.tar.gz) será feito antes de qualquer remoção — restaure com --restore."

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    warn "Esta ação é DESTRUTIVA. Há backup automático, mas restaurar é manual (--restore)."
    local confirm
    if [[ "$HAS_GUM" -eq 1 ]]; then
      confirm="$(gum input --header="Digite APAGAR para confirmar a operação acima" --placeholder="APAGAR")"
    else
      read -r -p "Digite APAGAR para confirmar a operação acima: " confirm
    fi
    if [[ "$confirm" != "APAGAR" ]]; then
      warn "Confirmação não corresponde a 'APAGAR'. Operação cancelada."
      exit 0
    fi
  fi

  run_delete_items "${SELECTED[@]}"

  echo
  ok "Concluído. Log completo em: $LOG_FILE"
  ok "Backups em: $BACKUP_ROOT (restaure com --restore)"
}

main
