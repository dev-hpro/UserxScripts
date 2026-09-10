// Package ui implementa a TUI (Bubbletea) do Scriptman: lista os scripts descobertos
// pelo catalog, mostra a documentação de cada um e executa o selecionado no host.
package ui

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"

	"github.com/dev-hpro/UserxScripts/frontend/internal/catalog"
	"github.com/dev-hpro/UserxScripts/frontend/internal/hostexec"
	"github.com/dev-hpro/UserxScripts/frontend/internal/update"
)

type focusArea int

const (
	focusList focusArea = iota
	focusDetail
	focusArgs
)

// Model é o estado da TUI.
type Model struct {
	sourceDir string
	checker   *update.Checker

	list     list.Model
	viewport viewport.Model
	argsIn   textinput.Model
	renderer *glamour.TermRenderer

	focus       focusArea
	width       int
	height      int
	listBoxW    int // largura renderizada da caixa da lista (com borda+padding), pra rotear mouse
	ready       bool
	statusMsg   string
	checkingNow bool
	pendingRun  *catalog.Script
	lastRunErr  error
	lastRunAt   time.Time
}

type scriptItem struct{ s catalog.Script }

func (i scriptItem) FilterValue() string {
	return strings.Join([]string{i.s.OS, i.s.Category, i.s.Feature, i.s.Name, i.s.Description}, " ")
}
func (i scriptItem) Title() string {
	return fmt.Sprintf("%s  %s/%s/%s", i.s.Name, i.s.OS, i.s.Category, i.s.Feature)
}
func (i scriptItem) Description() string {
	d := i.s.Description
	if idx := strings.IndexByte(d, '\n'); idx >= 0 {
		d = d[:idx]
	}
	return d
}

// New cria o model inicial a partir do diretório-fonte já resolvido (repo local em modo
// dev, ou a cópia baixada pelo update.Checker em modo Flatpak). checker pode ser nil
// (nesse caso não há verificação automática de update).
func New(sourceDir string, checker *update.Checker) Model {
	items := loadItems(sourceDir)

	delegate := list.NewDefaultDelegate()
	l := list.New(items, delegate, 0, 0)
	l.Title = "Scriptman — scripts do projeto"
	l.SetShowHelp(false)
	l.Styles.Title = titleStyle

	ti := textinput.New()
	ti.Placeholder = "argumentos (opcional) — Enter roda, Esc cancela"
	ti.CharLimit = 200

	vp := viewport.New(0, 0)
	vp.MouseWheelEnabled = true

	renderer, _ := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(80),
	)

	m := Model{
		sourceDir: sourceDir,
		checker:   checker,
		list:      l,
		viewport:  vp,
		argsIn:    ti,
		renderer:  renderer,
		statusMsg: "pronto",
	}
	return m
}

func loadItems(sourceDir string) []list.Item {
	scripts, err := catalog.Scan(sourceDir)
	if err != nil {
		return nil
	}
	items := make([]list.Item, 0, len(scripts))
	for _, s := range scripts {
		items = append(items, scriptItem{s})
	}
	return items
}

// Init dispara a checagem de update em background (se houver checker configurado).
func (m Model) Init() tea.Cmd {
	if m.checker == nil {
		return nil
	}
	return checkUpdateCmd(m.checker)
}

type updateResultMsg struct {
	res update.Result
	err error
}

type runFinishedMsg struct {
	script catalog.Script
	err    error
}

func checkUpdateCmd(c *update.Checker) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		res, err := c.EnsureUpToDate(ctx)
		return updateResultMsg{res: res, err: err}
	}
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ready = true
		const boxOverhead = 4 // borda (2) + padding horizontal (2) de cada caixa
		const gap = 1
		avail := m.width - gap
		listW := avail*2/5 - boxOverhead
		detailW := avail - avail*2/5 - boxOverhead
		if listW < 10 {
			listW = 10
		}
		if detailW < 10 {
			detailW = 10
		}
		headerH := 1
		footerH := 2
		bodyH := m.height - headerH - footerH
		if bodyH < 3 {
			bodyH = 3
		}
		m.listBoxW = listW + boxOverhead + gap
		m.list.SetSize(listW, bodyH)
		m.viewport.Width = detailW
		m.viewport.Height = bodyH
		if m.renderer != nil {
			r, _ := glamour.NewTermRenderer(glamour.WithAutoStyle(), glamour.WithWordWrap(detailW-2))
			m.renderer = r
		}
		m.syncDetail()
		return m, nil

	case updateResultMsg:
		m.checkingNow = false
		if msg.err != nil {
			m.statusMsg = "falha ao verificar atualização: " + msg.err.Error()
		} else if msg.res.Changed {
			m.statusMsg = fmt.Sprintf("atualizado: commit %s", shortSHA(msg.res.SHA))
			m.list.SetItems(loadItems(m.sourceDir))
		} else {
			m.statusMsg = fmt.Sprintf("já atualizado (commit %s)", shortSHA(msg.res.SHA))
		}
		return m, nil

	case runFinishedMsg:
		m.lastRunErr = msg.err
		m.lastRunAt = time.Now()
		if msg.err != nil {
			m.statusMsg = fmt.Sprintf("%s terminou com erro: %v", msg.script.Name, msg.err)
		} else {
			m.statusMsg = fmt.Sprintf("%s terminou com sucesso", msg.script.Name)
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)

	case tea.MouseMsg:
		// A roda do mouse controla o que estiver embaixo do cursor, direto —
		// independe de qual painel está com foco de teclado no momento.
		if msg.X < m.listBoxW {
			switch msg.Button {
			case tea.MouseButtonWheelUp:
				m.list.CursorUp()
				m.syncDetail()
			case tea.MouseButtonWheelDown:
				m.list.CursorDown()
				m.syncDetail()
			}
			return m, nil
		}
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}

	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	m.syncDetail()
	return m, cmd
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.focus == focusArgs {
		switch msg.String() {
		case "esc":
			m.focus = focusList
			m.pendingRun = nil
			m.statusMsg = "execução cancelada"
			return m, nil
		case "enter":
			script := *m.pendingRun
			args := strings.Fields(m.argsIn.Value())
			m.focus = focusList
			m.pendingRun = nil
			m.argsIn.SetValue("")
			m.statusMsg = "executando " + script.Name + "..."
			cmd := hostexec.BuildCommand(script.Path, args)
			return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
				return runFinishedMsg{script: script, err: err}
			})
		}
		var cmd tea.Cmd
		m.argsIn, cmd = m.argsIn.Update(msg)
		return m, cmd
	}

	if m.focus == focusDetail {
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "tab", "esc":
			m.focus = focusList
			return m, nil
		}
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}

	if m.list.FilterState() == list.Filtering {
		var cmd tea.Cmd
		m.list, cmd = m.list.Update(msg)
		m.syncDetail()
		return m, cmd
	}

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "tab":
		m.focus = focusDetail
		return m, nil
	case "u":
		if m.checker != nil && !m.checkingNow {
			m.checkingNow = true
			m.statusMsg = "verificando atualização..."
			return m, checkUpdateCmd(m.checker)
		}
		return m, nil
	case "enter":
		if it, ok := m.list.SelectedItem().(scriptItem); ok {
			s := it.s
			m.pendingRun = &s
			m.focus = focusArgs
			m.argsIn.Focus()
			m.argsIn.SetValue("")
			return m, textinput.Blink
		}
		return m, nil
	}

	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	m.syncDetail()
	return m, cmd
}

func (m *Model) syncDetail() {
	it, ok := m.list.SelectedItem().(scriptItem)
	if !ok {
		m.viewport.SetContent("selecione um script na lista à esquerda")
		return
	}
	s := it.s

	var b strings.Builder
	fmt.Fprintf(&b, "# %s\n\n", s.Name)
	fmt.Fprintf(&b, "`%s`\n\n", s.Path)
	if s.Description != "" {
		b.WriteString(s.Description)
		b.WriteString("\n\n")
	}
	if s.Usage != "" {
		b.WriteString("```\n")
		b.WriteString(s.Usage)
		b.WriteString("\n```\n\n")
	}
	if s.DocPath != "" {
		if doc, err := os.ReadFile(s.DocPath); err == nil {
			b.WriteString("---\n\n")
			b.WriteString(stripFrontmatter(string(doc)))
		}
	} else {
		b.WriteString("_(sem documentação em docs/ para este item)_\n")
	}

	content := b.String()
	if m.renderer != nil {
		if out, err := m.renderer.Render(content); err == nil {
			content = out
		}
	}
	m.viewport.SetContent(content)
	m.viewport.GotoTop()
}

func (m Model) View() string {
	if !m.ready {
		return "carregando..."
	}

	header := headerStyle.Width(m.width).Render("📜 Scriptman — gerenciador de scripts")

	listStyle, detailStyle := listBoxStyleBlurred, detailBoxStyleBlurred
	if m.focus == focusDetail {
		detailStyle = detailBoxStyleFocused
	} else {
		listStyle = listBoxStyleFocused
	}

	listView := listStyle.Render(m.list.View())
	detailView := detailStyle.Render(m.viewport.View())
	body := lipgloss.JoinHorizontal(lipgloss.Top, listView, " ", detailView)

	var footer string
	switch m.focus {
	case focusArgs:
		footer = fmt.Sprintf("▸ executar %s   argumentos: %s", m.pendingRun.Name, m.argsIn.View())
	case focusDetail:
		scroll := fmt.Sprintf("%3.0f%%", m.viewport.ScrollPercent()*100)
		footer = helpStyle.Render("documentação ("+scroll+") · ↑/↓ rola · pgup/pgdn/u/d página · tab volta pra lista · q sai") +
			"  ·  " + statusStyle.Render(m.statusMsg)
	default:
		footer = helpStyle.Render("↑/↓ navega · / busca · tab → doc (rola com mouse/setas) · enter executa · u atualiza · q sai") +
			"  ·  " + statusStyle.Render(m.statusMsg)
	}

	return lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
}

func shortSHA(sha string) string {
	if len(sha) > 8 {
		return sha[:8]
	}
	return sha
}

// stripFrontmatter remove o cabeçalho YAML (--- ... ---) do início de um doc Markdown —
// o glamour renderiza esse bloco como texto solto/regra horizontal, o que fica feio.
func stripFrontmatter(md string) string {
	trimmed := strings.TrimLeft(md, "\n")
	if !strings.HasPrefix(trimmed, "---") {
		return md
	}
	lines := strings.Split(trimmed, "\n")
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			return strings.TrimLeft(strings.Join(lines[i+1:], "\n"), "\n")
		}
	}
	return md
}
