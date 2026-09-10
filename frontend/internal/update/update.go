// Package update verifica se o repositório de scripts no GitHub mudou e, se sim, baixa a
// cópia mais nova. Não depende de git nem de token — usa a API pública do GitHub e o
// tarball do branch, por isso o repositório precisa ser público.
package update

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const (
	apiBase     = "https://api.github.com"
	archiveBase = "https://github.com"
)

// Checker cuida de checar/baixar o repositório dev-hpro/UserxScripts do GitHub.
type Checker struct {
	Owner string
	Repo  string
	Ref   string

	dataDir    string
	httpClient *http.Client
}

type state struct {
	SHA       string    `json:"sha"`
	UpdatedAt time.Time `json:"updated_at"`
}

// NewChecker cria um Checker usando o cache de usuário (~/.cache/scriptman, ou o
// equivalente redirecionado pelo sandbox do Flatpak para dentro do data-dir do app).
func NewChecker(owner, repo, ref string) (*Checker, error) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return nil, err
	}
	dataDir := filepath.Join(cacheDir, "scriptman")
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	return &Checker{
		Owner:      owner,
		Repo:       repo,
		Ref:        ref,
		dataDir:    dataDir,
		httpClient: &http.Client{Timeout: 60 * time.Second},
	}, nil
}

// RepoDir é o diretório onde a cópia extraída do repositório fica.
func (c *Checker) RepoDir() string {
	return filepath.Join(c.dataDir, "repo")
}

func (c *Checker) statePath() string {
	return filepath.Join(c.dataDir, "repo-state.json")
}

func (c *Checker) readState() state {
	var s state
	data, err := os.ReadFile(c.statePath())
	if err != nil {
		return s
	}
	_ = json.Unmarshal(data, &s)
	return s
}

func (c *Checker) writeState(s state) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.statePath(), data, 0o644)
}

// LatestSHA consulta a API do GitHub pelo commit mais recente do branch/ref configurado.
func (c *Checker) LatestSHA(ctx context.Context) (string, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/commits/%s", apiBase, c.Owner, c.Repo, c.Ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("github respondeu %d: %s", resp.StatusCode, string(body))
	}

	var payload struct {
		SHA string `json:"sha"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	return payload.SHA, nil
}

// Result descreve o resultado de uma verificação/atualização.
type Result struct {
	Changed bool
	SHA     string
	RepoDir string
}

// EnsureUpToDate checa o SHA mais recente no GitHub; se for diferente do que está salvo
// localmente (ou se ainda não existe cópia local), baixa o tarball do branch e substitui
// a cópia antiga de forma atômica.
func (c *Checker) EnsureUpToDate(ctx context.Context) (Result, error) {
	latest, err := c.LatestSHA(ctx)
	if err != nil {
		return Result{}, err
	}

	local := c.readState()
	_, statErr := os.Stat(c.RepoDir())
	if local.SHA == latest && statErr == nil {
		return Result{Changed: false, SHA: latest, RepoDir: c.RepoDir()}, nil
	}

	if err := c.download(ctx, latest); err != nil {
		return Result{}, err
	}
	if err := c.writeState(state{SHA: latest, UpdatedAt: time.Now()}); err != nil {
		return Result{}, err
	}
	return Result{Changed: true, SHA: latest, RepoDir: c.RepoDir()}, nil
}

func (c *Checker) download(ctx context.Context, sha string) error {
	url := fmt.Sprintf("%s/%s/%s/archive/refs/heads/%s.tar.gz", archiveBase, c.Owner, c.Repo, c.Ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download do tarball falhou: status %d", resp.StatusCode)
	}

	tmpDir, err := os.MkdirTemp(c.dataDir, "download-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	if err := extractTarGz(resp.Body, tmpDir); err != nil {
		return err
	}

	// o tarball do GitHub contém uma única pasta de topo (ex: UserxScripts-main).
	entries, err := os.ReadDir(tmpDir)
	if err != nil {
		return err
	}
	if len(entries) != 1 || !entries[0].IsDir() {
		return fmt.Errorf("formato inesperado do tarball baixado")
	}
	extracted := filepath.Join(tmpDir, entries[0].Name())

	old := c.RepoDir()
	staging := old + ".new"
	_ = os.RemoveAll(staging)
	if err := os.Rename(extracted, staging); err != nil {
		return err
	}
	_ = os.RemoveAll(old)
	if err := os.Rename(staging, old); err != nil {
		return err
	}
	return nil
}

func extractTarGz(r io.Reader, dest string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		target := filepath.Join(dest, hdr.Name)
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(hdr.Mode))
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			f.Close()
		}
	}
}
