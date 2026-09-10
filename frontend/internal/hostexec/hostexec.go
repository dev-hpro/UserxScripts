// Package hostexec monta o comando que executa um script de verdade: direto, quando o
// app roda fora de um sandbox, ou via `flatpak-spawn --host` quando roda empacotado como
// Flatpak (os scripts precisam alterar o sistema real, então não faz sentido roda-los
// dentro do sandbox).
package hostexec

import (
	"os"
	"os/exec"
)

// InFlatpak diz se o processo atual está rodando dentro de um sandbox Flatpak.
func InFlatpak() bool {
	return os.Getenv("FLATPAK_ID") != ""
}

// envForwardVars são as variáveis de ambiente relacionadas a terminal que o
// `flatpak-spawn --host` NÃO repassa sozinho (ele conecta a tty real, mas roda o processo
// do host com um ambiente limpo — sem isso TERM chega como "dumb" do lado de fora, e
// qualquer coisa baseada em ncurses (whiptail, dialog, gum) falha na hora de abrir,
// silenciosamente, sem essa forçada explícita via --env).
var envForwardVars = []string{"TERM", "COLORTERM", "LANG", "LC_ALL", "LC_CTYPE"}

// BuildCommand monta o *exec.Cmd para rodar scriptPath com args, escolhendo
// automaticamente entre execução direta e `flatpak-spawn --host` conforme o ambiente.
// Quem chamar é responsável por conectar Stdin/Stdout/Stderr (ex: via tea.ExecProcess).
func BuildCommand(scriptPath string, args []string) *exec.Cmd {
	if InFlatpak() {
		full := []string{"--host"}
		for _, v := range envForwardVars {
			if val := os.Getenv(v); val != "" {
				full = append(full, "--env="+v+"="+val)
			}
		}
		full = append(full, scriptPath)
		full = append(full, args...)
		return exec.Command("flatpak-spawn", full...)
	}
	return exec.Command(scriptPath, args...)
}
