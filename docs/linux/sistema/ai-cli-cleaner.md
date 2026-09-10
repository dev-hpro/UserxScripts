---
tags: [linux, sistema, ia, cli]
aliases: [ai-cli-cleaner, limpador de IAs]
---

# ai-cli-cleaner

Script: `[[../../../linux/sistema/ai-cli-cleaner/ai-cli-cleaner.sh]]`

## O que faz

TUI (interativo, via `whiptail` com fallback em modo texto puro) que:

1. Varre o sistema em busca de rastros de CLIs de IA instaladas — binário no `PATH`, pacote npm global, pacote pip/pipx, e pastas de config/cache/dados conhecidas.
2. Mostra ao usuário uma checklist com o que foi encontrado (e o tamanho ocupado em disco).
3. Deixa o usuário selecionar quais ferramentas deseja remover.
4. Antes de apagar, mostra exatamente o que será feito (comandos de desinstalação + caminhos a remover) e exige confirmação digitada explicitamente.
5. Oferece backup opcional (`.tar.gz`) das pastas antes de apagá-las.
6. Executa a remoção (desinstala pacote npm/pip/pipx quando aplicável, remove binário se estiver em local de usuário/`/usr/local`/`/opt`, remove diretórios de config/cache/dados) e grava log em `~/.ai-cli-cleaner/logs/`.

## Ferramentas cobertas por padrão

claude (Claude Code), gemini (Gemini CLI), antigravity, kimi, codex (OpenAI), copilot (GitHub Copilot CLI), cursor-agent, aider, q (Amazon Q), qwen (Qwen Code), opencode, goose, ollama, interpreter (Open Interpreter), llm, grok, deepseek.

A lista vive no array `TOOLS` no topo do script — adicionar uma ferramenta nova é só adicionar uma linha no formato:

```
"id|Nome de exibição|bin1,bin2|pkg-npm1,pkg-npm2|pkg-pip1,pkg-pip2|$HOME/.dir1,$HOME/.config/dir2"
```

## Como usar

```bash
./ai-cli-cleaner.sh            # fluxo interativo completo
./ai-cli-cleaner.sh --scan     # só escaneia e mostra o relatório, não remove nada
./ai-cli-cleaner.sh --dry-run  # roda o fluxo todo mas só mostra o que faria, sem tocar em nada
```

## Riscos / segurança

- **Ação destrutiva**: remove diretórios inteiros (`rm -rf`) e desinstala pacotes. Por isso exige que o usuário digite `APAGAR` para confirmar antes de qualquer remoção real.
- Binário só é removido automaticamente se estiver dentro de `$HOME`, `/usr/local/bin` ou `/opt` — binários gerenciados por `apt`/`dpkg` (em `/usr/bin`, `/bin`) **não** são tocados, o script apenas avisa.
- Backup é oferecido antes da remoção (pasta `~/.ai-cli-cleaner/backups/`), mas é opcional — se o usuário recusar, a remoção é permanente.
- Todo o fluxo é feito no escopo do usuário atual; não deve ser executado como `root`.

## Decisões

- Prioriza `whiptail` para a TUI (disponível por padrão no Debian/Ubuntu) com fallback em menu numerado puro-bash, para funcionar em qualquer distro Linux sem dependências extras.
- Detecção por evidência múltipla (binário + gerenciador de pacote + diretório) em vez de só checar se o binário existe, porque muitas dessas ferramentas deixam config/cache mesmo após desinstalar o pacote.
