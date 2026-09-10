#!/usr/bin/env bash
#
# scriptman-teste.sh — script de teste pra verificar que o Scriptman (o app
# em frontend/) puxa scripts novos automaticamente do GitHub, sem precisar
# reinstalar nada — é só o mecanismo de auto-update do Flatpak baixando o
# repositório público de novo.
#
# Não altera nada no sistema, só imprime informação. Seguro rodar.
#
# Uso:
#   ./scriptman-teste.sh          imprime uma mensagem de teste
#   ./scriptman-teste.sh --help   mostra esta ajuda

set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
scriptman-teste.sh — script de teste do auto-update do Scriptman.
Não altera nada no sistema, só imprime uma mensagem.
EOF
  exit 0
fi

echo "✅ o Scriptman puxou este script novo do GitHub com sucesso!"
echo "Rodando em: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Host: $(hostname)"
