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

// BuildCommand monta o *exec.Cmd para rodar scriptPath com args, escolhendo
// automaticamente entre execução direta e `flatpak-spawn --host` conforme o ambiente.
// Quem chamar é responsável por conectar Stdin/Stdout/Stderr (ex: via tea.ExecProcess).
func BuildCommand(scriptPath string, args []string) *exec.Cmd {
	if InFlatpak() {
		full := append([]string{"--host", scriptPath}, args...)
		return exec.Command("flatpak-spawn", full...)
	}
	return exec.Command(scriptPath, args...)
}
