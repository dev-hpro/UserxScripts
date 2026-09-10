# Scriptman

TUI para descobrir, ler a documentação e executar os scripts deste repositório
(UserxScripts). Detalhes completos em [`docs/frontend/scriptman.md`](../docs/frontend/scriptman.md).

## Rodando em modo dev

Sem precisar de Flatpak nem rede — usa o checkout local diretamente:

```bash
export PATH="$HOME/.local/go/bin:$PATH"   # se o Go estiver instalado em ~/.local/go
cd frontend
go run .
```

O app sobe a partir do diretório atual procurando a raiz do projeto (a pasta que contém
`AGENTS.md`). Pra forçar outro diretório-fonte:

```bash
SCRIPTMAN_SOURCE_DIR=/caminho/para/outro/checkout go run .
```

Atalhos: `↑`/`↓` navega, `/` filtra, `Enter` executa o script selecionado (pede argumentos
opcionais antes), `u` força verificação de atualização, `q` sai.

## Empacotando como Flatpak (100% userspace, sem root)

Pré-requisitos (uma vez só, tudo `--user`):

```bash
flatpak install --user flathub \
  org.freedesktop.Platform//24.08 \
  org.freedesktop.Sdk//24.08 \
  org.freedesktop.Sdk.Extension.golang//24.08
```

Build + instalação:

```bash
cd frontend
go mod vendor   # se ainda não tiver frontend/vendor/ atualizado com as dependências
flatpak-builder --user --install --force-clean build-dir flatpak/io.github.dev_hpro.Scriptman.yml
```

Rodar:

```bash
flatpak run io.github.dev_hpro.Scriptman
```

O `.desktop` instalado (`Terminal=true`) também aparece no menu de aplicativos e abre num
terminal.

### Como funciona a auto-atualização

Dentro do Flatpak, a cada abertura o app confere o commit mais recente do branch `main` em
`dev-hpro/UserxScripts` via API pública do GitHub (sem token — por isso o repositório
precisa ser público). Se mudou, baixa o tarball do repositório e substitui a cópia antiga
guardada em `~/.var/app/io.github.dev_hpro.Scriptman/cache/scriptman/repo` (dado próprio do
app, sem precisar de permissão extra de filesystem). `u` força essa verificação manualmente.

### Como funciona a execução dos scripts

Os scripts alteram o sistema de verdade (ex.: `ai-cli-cleaner.sh` limpa `$HOME`), então
rodá-los isolados dentro do sandbox não serviria pra nada. O Flatpak pede a permissão
`--talk-name=org.freedesktop.Flatpak` e usa `flatpak-spawn --host` pra executar o script
escolhido no sistema real, com o terminal suspenso e conectado diretamente (prompts
interativos do próprio script — como os menus `whiptail` do `ai-cli-uninstaller.sh` —
funcionam normalmente).
