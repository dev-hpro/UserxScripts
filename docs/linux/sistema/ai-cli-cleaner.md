---
tags: [linux, sistema, ia, cli]
aliases: [ai-cli-cleaner, limpador de IAs]
---

# ai-cli-cleaner

Script: `[[../../../linux/sistema/ai-cli-cleaner/ai-cli-cleaner.sh]]`

## O que faz

TUI (interativo, via `whiptail` com fallback em modo texto puro) que:

1. Varre o sistema em busca de rastros de CLIs de IA instaladas — binário no `PATH`, pacote npm global, pacote pip/pipx, e pastas de cache/dados/credenciais conhecidas (três categorias, ver abaixo).
2. Mostra um relatório com o que foi encontrado: tamanho total, tamanho de cache e tamanho de dados/sessões.
3. Pergunta o **nível**: `basic`, `full` ou `purge` (ver abaixo).
4. Mostra uma checklist (múltipla seleção) só com as ferramentas elegíveis para o nível escolhido, e deixa escolher uma ou várias.
5. Antes de agir, mostra exatamente o que será feito (comandos de desinstalação + caminhos) e exige confirmação digitada explicitamente (`APAGAR`).
6. Faz backup automático (`.tar.gz`, sempre — não é opcional) de tudo que vai ser apagado, **antes** de apagar. Se o backup falhar por qualquer motivo, a remoção daquela ferramenta é cancelada e nada é tocado.
7. Executa a operação e grava log em `~/.ai-cli-cleaner/logs/`.
8. `--restore` lista os backups feitos e restaura o escolhido de volta para os caminhos originais.

### Níveis

- **`basic`** (limpeza básica) — apaga só os diretórios de **cache/temporários** (regeneráveis) de cada ferramenta selecionada. Não toca em sessões, config ou credenciais. Só aparecem nesse nível as ferramentas que de fato têm cache detectado.
- **`full`** (limpeza completa) — apaga cache **+ dados/sessões/histórico** (ex.: todo o histórico de conversas do Claude Code, incluindo a pasta de memória entre sessões). **Não desinstala o pacote e não apaga credenciais/config** — a ferramenta continua instalada e logada depois. Plugins, hooks, skills e o `settings.json` ficam preservados (são configuração deliberada, não histórico).
- **`purge`** (desinstalação completa) — remove absolutamente tudo: desinstala o pacote (npm/pip/pipx), apaga cache + dados + credenciais/config, e remove o binário se estiver em local de usuário (`$HOME`, `/usr/local/bin` ou `/opt`).

Pode pular a pergunta do nível com `--mode=basic`, `--mode=full` ou `--mode=purge`.

### Restaurar um backup

```bash
./ai-cli-cleaner.sh --restore
```

Lista os `.tar.gz` em `~/.ai-cli-cleaner/backups/` (mais recente primeiro), mostra o que cada um contém e, ao confirmar, copia cada caminho de volta para o lugar original. Se algum caminho de destino já existir (por exemplo, a ferramenta já recriou parte do cache desde o backup), o estado atual dele é salvo antes em `~/.ai-cli-cleaner/backups/.pre-restore-<timestamp>/` — a restauração nunca sobrescreve nada sem guardar uma cópia de segurança do que havia ali.

## Ferramentas cobertas por padrão

claude (Claude Code), gemini (Gemini CLI), antigravity, kimi, codex (OpenAI), copilot (GitHub Copilot CLI), cursor-agent, aider, q (Amazon Q), qwen (Qwen Code), opencode, goose, ollama, interpreter (Open Interpreter), llm, grok, deepseek.

A lista vive no array `TOOLS` no topo do script — adicionar uma ferramenta nova é só adicionar uma linha no formato:

```
"id|Nome de exibição|bin1,bin2|pkg-npm1,pkg-npm2|pkg-pip1,pkg-pip2|dirs-cache|dirs-dados|dirs-manter"
```

Onde:
- **cache** (5º campo antes do fim) — regenerável, apagado já no nível `basic`.
- **dados** (6º campo) — sessões, histórico, config de uso etc.; não é necessário para login nem para o binário funcionar, mas não é regenerado sozinho; apagado no nível `full` (mantém logado e instalado).
- **manter** (último campo) — credenciais/login, config de conectores/plugins/hooks, e o que for necessário para o binário continuar funcionando; só é apagado no `purge`.

**Importante:** só a entrada `claude` foi auditada de fato neste sistema (os três campos refletem a estrutura real de `~/.claude`). Para as outras 16 ferramentas, o campo "dados" está vazio por padrão — nesse caso `full` se comporta igual a `basic` até alguém confirmar a estrutura real de arquivos daquela ferramenta e popular o campo. É proposital: é mais seguro não apagar por suposição.

## Como usar

```bash
./ai-cli-cleaner.sh                 # fluxo interativo completo (pergunta o nível)
./ai-cli-cleaner.sh --mode=basic    # vai direto pra limpeza básica (só cache)
./ai-cli-cleaner.sh --mode=full     # vai direto pra limpeza completa (mantém logado)
./ai-cli-cleaner.sh --mode=purge    # vai direto pra desinstalação completa
./ai-cli-cleaner.sh --restore       # restaura um backup feito anteriormente
./ai-cli-cleaner.sh --scan          # só escaneia e mostra o relatório, não altera nada
./ai-cli-cleaner.sh --dry-run       # roda o fluxo todo mas só mostra o que faria, sem tocar em nada
```

## Riscos / segurança

- **Ação destrutiva**: remove diretórios inteiros (`rm -rf`) e, no `purge`, desinstala pacotes. Por isso exige que o usuário digite `APAGAR` para confirmar antes de qualquer remoção real, nos três níveis.
- **Backup é sempre feito antes de apagar**, sem perguntar — e a remoção só acontece se o backup for garantido. Se `cp` ou `tar` falharem por qualquer motivo (disco cheio, permissão, dependência faltando), a operação inteira daquela ferramenta é cancelada e nada é tocado.
- O backup preserva a árvore de diretórios original completa (via `cp -a --parents`), não um nome achatado — isso é o que permite ao `--restore` devolver cada arquivo exatamente para onde estava.
- No nível `basic`, só os diretórios marcados como cache no registro são candidatos — nunca dados, config ou credenciais.
- No nível `full`, credenciais, config de plugins/hooks/skills e `settings.json` nunca são tocados — só dados/histórico (incluindo, no caso do Claude Code, a pasta de memória entre sessões: vale um aviso extra na tela antes de confirmar).
- Binário só é removido automaticamente (nível `purge`) se estiver dentro de `$HOME`, `/usr/local/bin` ou `/opt` — binários gerenciados por `apt`/`dpkg` (em `/usr/bin`, `/bin`) **não** são tocados, o script apenas avisa.
- Todo o fluxo é feito no escopo do usuário atual; não deve ser executado como `root`.

## Decisões

- Prioriza `whiptail` para a TUI (disponível por padrão no Debian/Ubuntu) com fallback em menu numerado puro-bash, para funcionar em qualquer distro Linux sem dependências extras. O fallback manda toda mensagem informativa/prompt para stderr — a função de seleção é chamada dentro de um `$(...)`, então qualquer `echo` sem redirecionamento nela vaza para dentro do valor capturado.
- Detecção por evidência múltipla (binário + gerenciador de pacote + diretório) em vez de só checar se o binário existe, porque muitas dessas ferramentas deixam config/cache mesmo após desinstalar o pacote.
- Três categorias de diretório (cache/dados/manter) em vez de duas, especificamente para viabilizar um nível intermediário (`full`) que libera bastante espaço e apaga histórico sem exigir login de novo nem reinstalar nada.
- Backup obrigatório (não opcional) com verificação de sucesso antes de apagar: a versão anterior perguntava "quer fazer backup?" e prosseguia com a remoção mesmo se o backup falhasse — isso já causou perda de dados reais durante o desenvolvimento (histórico de sessões do Claude Code apagado num teste que pulou o fluxo normal do script). Depois disso, backup deixou de ser opcional e passou a bloquear a remoção se não puder ser garantido.
- O backup usa `cp -a --parents` (preserva a árvore completa a partir de `/`) em vez de achatar o caminho num nome de arquivo — a versão anterior fazia `sed 's#/#_#g'`, que é ambíguo (um path com `_` no nome colide com a codificação) e não dava para restaurar com confiança. Isso é o que viabiliza o `--restore` funcionar de verdade.
