// Scriptman — TUI para descobrir, documentar e executar os scripts deste projeto.
//
// Modo dev (fora de um sandbox Flatpak): usa o repositório local diretamente, procurando
// a raiz do projeto a partir do diretório atual (marcada pelo AGENTS.md).
//
// Modo Flatpak: baixa/atualiza a cópia do repositório público a partir do GitHub
// (dev-hpro/UserxScripts) e executa os scripts no host via `flatpak-spawn --host`.
//
// SCRIPTMAN_SOURCE_DIR força um diretório-fonte específico em qualquer modo (útil pra
// testar sem depender de rede).
package main

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/dev-hpro/UserxScripts/frontend/internal/hostexec"
	"github.com/dev-hpro/UserxScripts/frontend/internal/ui"
	"github.com/dev-hpro/UserxScripts/frontend/internal/update"
)

const (
	repoOwner = "dev-hpro"
	repoName  = "UserxScripts"
	repoRef   = "main"
)

func main() {
	sourceDir, checker, err := resolveSource()
	if err != nil {
		fmt.Fprintln(os.Stderr, "erro:", err)
		os.Exit(1)
	}

	p := tea.NewProgram(ui.New(sourceDir, checker), tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "erro:", err)
		os.Exit(1)
	}
}

func resolveSource() (string, *update.Checker, error) {
	if dir := os.Getenv("SCRIPTMAN_SOURCE_DIR"); dir != "" {
		return dir, nil, nil
	}

	if hostexec.InFlatpak() {
		checker, err := update.NewChecker(repoOwner, repoName, repoRef)
		if err != nil {
			return "", nil, err
		}
		return checker.RepoDir(), checker, nil
	}

	dir, err := findProjectRoot()
	if err != nil {
		return "", nil, err
	}
	return dir, nil, nil
}

// findProjectRoot sobe a partir do diretório atual até achar a pasta que contém o
// AGENTS.md do projeto (marca a raiz do repositório de scripts).
func findProjectRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "AGENTS.md")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("não encontrei a raiz do projeto (AGENTS.md) a partir de %s; defina SCRIPTMAN_SOURCE_DIR", dir)
		}
		dir = parent
	}
}
