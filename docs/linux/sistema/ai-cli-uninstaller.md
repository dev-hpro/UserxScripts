---
tags: [linux, sistema, ia, cli]
aliases: [ai-cli-uninstaller, desinstalador configurável]
---

# ai-cli-uninstaller

Script: `[[../../../linux/sistema/ai-cli-uninstaller/ai-cli-uninstaller.sh]]`

Variante do [[ai-cli-cleaner]] com seleção **granular**: em vez de escolher um nível (básico/completo/purge) aplicado a ferramentas inteiras, aqui cada item — cada diretório de cache, cada pasta de dados, cada credencial, cada pacote npm/pip/pipx, cada binário — é uma linha selecionável independente, com o próprio tamanho em disco. Dá pra misturar itens de várias ferramentas na mesma seleção (ex.: cache do Claude Code + credenciais do Gemini CLI + pacote npm do Codex, tudo numa passada só).

Usa o mesmo `TOOLS` registry, o mesmo formato de backup e a mesma pasta de estado (`~/.ai-cli-cleaner/`) do `ai-cli-cleaner.sh` — os backups são intercambiáveis: um backup feito por um dos dois scripts pode ser restaurado pelo outro.

## O que faz

1. Varre o sistema (mesma detecção do `ai-cli-cleaner.sh`: binário, pacote npm/pip/pipx, diretórios de cache/dados/credenciais).
2. Constrói uma lista plana de itens — um por linha de evidência — agrupada visualmente por ferramenta, cada um com tamanho individual (via `du`, mesmo critério de disco usado no `-h`) e o consumo total detectado.
3. Deixa selecionar (checklist multi-seleção via `whiptail`, ou numerada em texto puro) qualquer combinação de itens, de qualquer ferramenta.
4. Mostra o resumo do que foi selecionado e o espaço estimado que será liberado.
5. Faz backup automático (sempre, não opcional) de todos os caminhos de arquivo selecionados antes de mexer em qualquer coisa — se o backup falhar, a operação inteira é cancelada (nem os `npm/pip/pipx uninstall` nem o `rm` rodam).
6. Exige confirmação escrita (`APAGAR`).
7. Executa: desinstala pacotes selecionados, apaga diretórios/arquivos selecionados, remove binários selecionados (só se estiverem em escopo de usuário: `$HOME`, `/usr/local/bin`, `/opt`).
8. `--restore` — igual ao `ai-cli-cleaner.sh` — lista os backups e devolve cada caminho ao lugar original.

## Como usar

```bash
./ai-cli-uninstaller.sh             # fluxo interativo completo
./ai-cli-uninstaller.sh --restore   # restaura um backup feito anteriormente
./ai-cli-uninstaller.sh --scan      # só escaneia e mostra o relatório de itens
./ai-cli-uninstaller.sh --dry-run   # roda o fluxo todo mas só mostra o que faria
./ai-cli-uninstaller.sh --yes       # pula a confirmação por escrito (ainda pede o "APAGAR")
```

## Riscos / segurança

- Mesmas garantias do `ai-cli-cleaner.sh`: backup sempre feito antes de apagar, remoção cancelada por completo se o backup não puder ser garantido, confirmação escrita obrigatória.
- Como a seleção é livre por item, é possível apagar credenciais de uma ferramenta enquanto mantém dados de outra — a tela de resumo antes da confirmação lista exatamente cada item selecionado com sua categoria (cache/dados/credenciais/pacote/binário) para deixar isso explícito.
- Se o item selecionado for a pasta `~/.claude/projects` do Claude Code, um aviso extra aparece no resumo: ela contém a subpasta `memory/` (memória entre sessões).
- O tamanho de itens do tipo pacote (npm/pip/pipx) e binário não é calculado (mostrado como `-`) — o cálculo de espaço a liberar cobre só os itens de diretório/arquivo (cache, dados, credenciais/config), que é onde o grosso do espaço em disco costuma estar.

## Decisões

- Reaproveita quase todo o código de detecção, backup e restore do `ai-cli-cleaner.sh` (mesmo `TOOLS`, mesmas constantes de manifesto) — a diferença real está só na camada de seleção/execução: uma lista plana de itens em vez de um modo fixo por ferramenta.
- `bytes_of()` usa `du -sk` (uso real em disco) em vez de `du -sb` (tamanho aparente do conteúdo) — a primeira versão usava `-sb` e subestimava bastante o total em diretórios com muitos arquivos pequenos, porque ignora arredondamento de bloco/inode. `-sk` bate com o critério usado no `human_size()` (`du -sh`) de cada item.
- O fallback em texto puro (`select_items_plain`) devolve a seleção numa única linha (`printf '%s\n' "${selected[*]}"`, não `"${selected[@]}"`) porque quem chama lê com `read -ra ARR <<<"$saida"` — isso só pega a primeira linha de uma string multi-linha. A versão inicial usava `[@]` (uma linha por item) e isso fazia qualquer seleção de mais de um item, via texto puro, silenciosamente processar só o primeiro. Esse mesmo padrão existe no fallback de texto do `ai-cli-cleaner.sh` (nunca corrigido lá).
