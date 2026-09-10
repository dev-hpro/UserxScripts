---
tags: [frontend, tui, flatpak, go]
aliases: [Scriptman, gerenciador de scripts]
---

# Scriptman

App: `[[../../frontend]]` (código em `frontend/`, instruções de build/execução em `[[../../frontend/README.md]]`)

## O que faz

TUI (Bubbletea, em Go) que descobre, documenta e executa os scripts deste repositório.
Existe em dois modos:

- **Modo dev**: roda direto (`go run .` dentro de `frontend/`) usando o checkout local do
  repositório como fonte — sem rede, sem Flatpak.
- **Modo Flatpak**: empacotado como app Flatpak rodando inteiramente em userspace
  (`flatpak-builder --user`, sem root). Ao abrir, confere o commit mais recente do branch
  `main` de [dev-hpro/UserxScripts](https://github.com/dev-hpro/UserxScripts) via API
  pública do GitHub e, se houver mudança, baixa e substitui a cópia local automaticamente
  — pega scripts novos e atualiza os existentes sem precisar de `git` instalado.

### Navegação

1. Varre `<so>/<categoria>/<funcionalidade>/*` no diretório-fonte (local ou baixado) e monta
   uma árvore navegável (lista à esquerda, filtrável com `/`).
2. Pra cada script, extrai o próprio bloco de comentários do topo do arquivo (descrição +
   seção `Uso:`) e localiza o `.md` correspondente em `docs/`, renderizando tudo junto
   (Glamour) no painel de detalhe à direita.
3. `Enter` sobre um script pede argumentos opcionais e executa de verdade.

### Execução

Os scripts deste projeto alteram o sistema real (ex.: `ai-cli-cleaner.sh` limpa `$HOME`),
então o app **executa no host**, não dentro de um sandbox isolado:

- Fora do Flatpak: `exec.Command` direto no script.
- Dentro do Flatpak: `flatpak-spawn --host`, usando a permissão
  `--talk-name=org.freedesktop.Flatpak` (a permissão mínima/padrão pra isso, sem precisar
  de `--filesystem=host`).

Em ambos os casos a TUI é suspensa e o script roda com stdio conectado direto ao terminal
real — prompts interativos do próprio script (ex.: os menus `whiptail` do
`ai-cli-uninstaller.sh`) funcionam normalmente.

### Atualização (só no Flatpak)

- `GET /repos/dev-hpro/UserxScripts/commits/main` (API pública do GitHub, sem token) pra
  saber o SHA mais recente.
- Se for diferente do salvo localmente (`repo-state.json`, dentro do cache próprio do app),
  baixa `archive/refs/heads/main.tar.gz` e substitui a cópia antiga (extração pra pasta
  temporária + rename atômico).
- Atalho `u` força essa verificação manualmente; também roda automaticamente (em background)
  ao abrir o app.

## Riscos

- O app pode **executar scripts destrutivos de verdade** (o `ai-cli-cleaner.sh` em modo
  `purge`, por exemplo). O app em si não adiciona nenhuma confirmação própria além da que já
  existe no script — as confirmações e dry-runs de cada script continuam sendo a única
  proteção.
- A auto-atualização do Flatpak **substitui a cópia local inteira** a cada commit novo em
  `main` — não há revisão manual antes de trocar os scripts que serão executados.

## Decisões relevantes

- **Repositório público**: o mecanismo de update usa a API/tarball públicos do GitHub sem
  token embutido no Flatpak, então `dev-hpro/UserxScripts` precisa ser público (revisado
  antes da troca — nenhum segredo/credencial encontrado nos scripts/docs).
- **Go + Bubbletea**: compila num binário único estático, o que deixa o manifest do
  Flatpak simples (sem vendoring de pip/cargo). As dependências Go ficam vendorizadas em
  `frontend/vendor/` justamente pra o build do Flatpak não precisar de rede.
