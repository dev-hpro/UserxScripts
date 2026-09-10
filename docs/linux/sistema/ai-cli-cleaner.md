---
tags: [linux, sistema, ia, cli]
aliases: [ai-cli-cleaner, limpador de IAs]
---

# ai-cli-cleaner

Script: `[[../../../linux/sistema/ai-cli-cleaner/ai-cli-cleaner.sh]]`

## O que faz

TUI (interativo, via `whiptail` com fallback em modo texto puro) que:

1. Varre o sistema em busca de rastros de CLIs de IA instaladas — binário no `PATH`, pacote npm global, pacote pip/pipx, e pastas de cache/temp e de config/dados conhecidas (separadas em duas categorias, ver abaixo).
2. Mostra um relatório com o que foi encontrado, o tamanho total e o tamanho só de cache/temp.
3. Pergunta o **modo**: `full` (remoção completa) ou `clean` (só cache/temporários).
4. Mostra uma checklist (múltipla seleção) só com as ferramentas elegíveis para o modo escolhido, e deixa escolher uma ou várias.
5. Antes de apagar, mostra exatamente o que será feito (comandos de desinstalação + caminhos) e exige confirmação digitada explicitamente (`APAGAR`).
6. Oferece backup opcional (`.tar.gz`) dos caminhos afetados antes de apagá-los.
7. Executa a operação e grava log em `~/.ai-cli-cleaner/logs/`.

### Modos

- **`clean`** — apaga só os diretórios de cache/temporários (regeneráveis) de cada ferramenta selecionada. Não desinstala pacote, não toca em config/credenciais, não remove o binário. Serve para liberar espaço em disco mantendo a ferramenta instalada e logada. Só aparecem nesse modo as ferramentas que de fato têm cache/temp detectado.
- **`full`** — remoção completa: desinstala o pacote (npm/pip/pipx), apaga cache **e** config/dados, e remove o binário se estiver em local de usuário (`$HOME`, `/usr/local/bin` ou `/opt`).

Pode pular a pergunta do modo com `--mode=clean` ou `--mode=full`.

## Ferramentas cobertas por padrão

claude (Claude Code), gemini (Gemini CLI), antigravity, kimi, codex (OpenAI), copilot (GitHub Copilot CLI), cursor-agent, aider, q (Amazon Q), qwen (Qwen Code), opencode, goose, ollama, interpreter (Open Interpreter), llm, grok, deepseek.

A lista vive no array `TOOLS` no topo do script — adicionar uma ferramenta nova é só adicionar uma linha no formato:

```
"id|Nome de exibição|bin1,bin2|pkg-npm1,pkg-npm2|pkg-pip1,pkg-pip2|$HOME/.cache/dir|$HOME/.config/dir,$HOME/.outra-config"
```

Onde o 5º campo (antes do último `|`) são os diretórios de **cache/temp** (safe para o modo `clean`) e o último campo são os diretórios de **config/dados** (só removidos no modo `full`).

## Como usar

```bash
./ai-cli-cleaner.sh                 # fluxo interativo completo (pergunta o modo)
./ai-cli-cleaner.sh --mode=clean    # vai direto pro modo "só cache/temporários"
./ai-cli-cleaner.sh --mode=full     # vai direto pro modo "remoção completa"
./ai-cli-cleaner.sh --scan          # só escaneia e mostra o relatório, não altera nada
./ai-cli-cleaner.sh --dry-run       # roda o fluxo todo mas só mostra o que faria, sem tocar em nada
```

## Riscos / segurança

- **Ação destrutiva**: remove diretórios inteiros (`rm -rf`) e desinstala pacotes (no modo `full`). Por isso exige que o usuário digite `APAGAR` para confirmar antes de qualquer remoção real, nos dois modos.
- No modo `clean`, só os diretórios marcados como cache/temp no registro são candidatos — nunca config/credenciais/binário.
- Binário só é removido automaticamente (modo `full`) se estiver dentro de `$HOME`, `/usr/local/bin` ou `/opt` — binários gerenciados por `apt`/`dpkg` (em `/usr/bin`, `/bin`) **não** são tocados, o script apenas avisa.
- Backup é oferecido antes da remoção (pasta `~/.ai-cli-cleaner/backups/`), mas é opcional — se o usuário recusar, a remoção é permanente.
- Todo o fluxo é feito no escopo do usuário atual; não deve ser executado como `root`.

## Decisões

- Prioriza `whiptail` para a TUI (disponível por padrão no Debian/Ubuntu) com fallback em menu numerado puro-bash, para funcionar em qualquer distro Linux sem dependências extras.
- Detecção por evidência múltipla (binário + gerenciador de pacote + diretório) em vez de só checar se o binário existe, porque muitas dessas ferramentas deixam config/cache mesmo após desinstalar o pacote.
- Cache/temp e config/dados são campos separados no registro (em vez de uma lista única de diretórios) especificamente para viabilizar o modo `clean` sem risco de apagar credenciais/config junto.
