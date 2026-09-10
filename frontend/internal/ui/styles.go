package ui

import "github.com/charmbracelet/lipgloss"

var (
	accent = lipgloss.AdaptiveColor{Light: "#6C4FE0", Dark: "#A78BFA"}
	muted  = lipgloss.AdaptiveColor{Light: "#6B6F76", Dark: "#8B8F98"}

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#FAFAFA")).
			Background(accent).
			Padding(0, 1)

	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(accent)

	baseBoxStyle = lipgloss.NewStyle().
			Padding(0, 1)

	// O painel com foco de teclado ganha borda grossa + cor de destaque; o outro
	// fica com borda fina cinza — indica de forma clara qual painel vai reagir
	// às teclas (lista navega/executa vs documentação rola).
	listBoxStyleFocused = baseBoxStyle.
				Border(lipgloss.ThickBorder()).
				BorderForeground(accent)
	listBoxStyleBlurred = baseBoxStyle.
				Border(lipgloss.RoundedBorder()).
				BorderForeground(muted)

	detailBoxStyleFocused = baseBoxStyle.
				Border(lipgloss.ThickBorder()).
				BorderForeground(accent)
	detailBoxStyleBlurred = baseBoxStyle.
				Border(lipgloss.RoundedBorder()).
				BorderForeground(muted)

	helpStyle = lipgloss.NewStyle().Foreground(muted)

	statusStyle = lipgloss.NewStyle().Foreground(accent)
)
