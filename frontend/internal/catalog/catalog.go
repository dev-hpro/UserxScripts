// Package catalog descobre os scripts do projeto (sistema-operacional/categoria/funcionalidade)
// e casa cada um com sua documentação em docs/, seguindo a convenção descrita no AGENTS.md.
package catalog

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Script representa um script encontrado na árvore do projeto.
type Script struct {
	OS          string // ex: "linux"
	Category    string // ex: "sistema" (pode ter subpastas, ex: "sistema/rede")
	Feature     string // ex: "ai-cli-cleaner"
	Name        string // nome do arquivo, ex: "ai-cli-cleaner.sh"
	Path        string // caminho absoluto do script
	Description string // texto extraído do bloco de comentários no topo do script
	Usage       string // trecho da seção "Uso:" dentro do header, se existir
	DocPath     string // caminho absoluto do .md correspondente em docs/, "" se não achou
}

// Label retorna um identificador curto e legível pra exibição em listas.
func (s Script) Label() string {
	return s.OS + "/" + s.Category + "/" + s.Feature
}

var scriptExt = map[string]bool{
	".sh":      true,
	".bash":    true,
	".ps1":     true,
	".bat":     true,
	".cmd":     true,
	".py":      true,
	".command": true,
}

var osDirs = map[string]bool{
	"linux":   true,
	"macos":   true,
	"windows": true,
}

// Scan varre root/{linux,macos,windows}/**/* procurando scripts e retorna a lista
// ordenada (por OS, categoria, funcionalidade, nome).
func Scan(root string) ([]Script, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}

	var scripts []Script
	for _, e := range entries {
		if !e.IsDir() || !osDirs[e.Name()] {
			continue
		}
		osName := e.Name()
		osRoot := filepath.Join(root, osName)
		err := filepath.Walk(osRoot, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() {
				return nil
			}
			if !scriptExt[strings.ToLower(filepath.Ext(info.Name()))] {
				return nil
			}
			rel, err := filepath.Rel(osRoot, path)
			if err != nil {
				return nil
			}
			parts := strings.Split(filepath.ToSlash(filepath.Dir(rel)), "/")
			if len(parts) == 0 || parts[0] == "." {
				// script direto em <os>/<arquivo>, sem categoria/funcionalidade — ignora,
				// não segue a convenção do projeto.
				return nil
			}
			feature := parts[len(parts)-1]
			category := strings.Join(parts[:len(parts)-1], "/")
			if category == "" {
				category = feature
			}

			desc, usage := parseHeader(path)
			docPath := findDoc(root, osName, category, feature)

			scripts = append(scripts, Script{
				OS:          osName,
				Category:    category,
				Feature:     feature,
				Name:        info.Name(),
				Path:        path,
				Description: desc,
				Usage:       usage,
				DocPath:     docPath,
			})
			return nil
		})
		if err != nil {
			return nil, err
		}
	}

	sort.Slice(scripts, func(i, j int) bool {
		a, b := scripts[i], scripts[j]
		if a.OS != b.OS {
			return a.OS < b.OS
		}
		if a.Category != b.Category {
			return a.Category < b.Category
		}
		if a.Feature != b.Feature {
			return a.Feature < b.Feature
		}
		return a.Name < b.Name
	})

	return scripts, nil
}

// findDoc localiza docs/<os>/<category>/<feature>.md, espelhando a estrutura dos scripts.
func findDoc(root, osName, category, feature string) string {
	candidate := filepath.Join(root, "docs", osName, category, feature+".md")
	if _, err := os.Stat(candidate); err == nil {
		return candidate
	}
	return ""
}

// parseHeader lê o bloco de comentários no topo do arquivo (pulando o shebang) e separa
// a descrição geral da seção "Uso:", se existir.
func parseHeader(path string) (description, usage string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", ""
	}
	lines := strings.Split(string(data), "\n")

	var block []string
	for i, line := range lines {
		if i == 0 && strings.HasPrefix(line, "#!") {
			continue
		}
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "#") {
			break
		}
		block = append(block, strings.TrimPrefix(strings.TrimPrefix(trimmed, "#"), " "))
	}

	full := strings.Join(block, "\n")
	full = strings.TrimSpace(full)

	if idx := strings.Index(full, "Uso:"); idx >= 0 {
		return strings.TrimSpace(full[:idx]), strings.TrimSpace(full[idx:])
	}
	return full, ""
}
