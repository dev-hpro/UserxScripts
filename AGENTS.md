# Script Builder

Esse projeto consiste em criação de scripts para uso rotineiro assim como suas documentações para reutilização, é importante que os scripts criados neste projeto possam ser utilizados em outros computadores, é necessário separar por categoria, funcionalidade, sistema operacional etc.

## Estrutura de pastas

Os scripts ficam separados por sistema operacional > categoria > funcionalidade, por exemplo:

```
linux/sistema/ai-cli-cleaner/ai-cli-cleaner.sh
windows/rede/...
macos/backup/...
```

## Documentação

- Toda documentação vive em `docs/`, espelhando a mesma estrutura de pastas usada para os scripts (sistema operacional > categoria > funcionalidade).
- `docs/` é o vault do Obsidian deste projeto — abra essa pasta diretamente no Obsidian para navegar e mapear tudo.
- Use recursos do Obsidian nos arquivos: links internos `[[nome-do-arquivo]]`, frontmatter YAML (`tags`, `aliases`) e o arquivo `docs/Home.md` como índice geral, linkando para a documentação de cada script.
- Todo script novo precisa de um `.md` correspondente em `docs/` descrevendo: o que faz, como usar, dependências, riscos (se for destrutivo) e decisões relevantes.

## Repositório Git

- Este projeto é versionado no repositório privado `UserxScripts` (GitHub, conta `dev-hpro`).
- Todo trabalho (scripts, documentação, ajustes) deve ser commitado e enviado (push) para esse repositório, mantendo tudo organizado e separado por pastas conforme a estrutura acima.
