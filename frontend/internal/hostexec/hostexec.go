// Package hostexec monta o comando que executa um script de verdade: direto, quando o
// app roda fora de um sandbox, ou via `flatpak-spawn --host` quando roda empacotado como
// Flatpak (os scripts precisam alterar o sistema real, então não faz sentido roda-los
// dentro do sandbox).
package hostexec

import (
	"os"
	"os/exec"
	"strings"
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
		// scriptPath aqui é sempre a cópia baixada em nosso próprio cache — não o
		// repositório original. Forçar +x é defensivo: um arquivo pode chegar sem
		// o bit de execução por qualquer detalhe do jeito como foi commitado/
		// baixado (já aconteceu: um arquivo criado via API do GitHub sem o modo
		// certo), e sem +x o exec falha com "permission denied" e o script nem
		// chega a rodar.
		_ = os.Chmod(scriptPath, 0o755)

		full := []string{"--host"}
		for _, v := range envForwardVars {
			if val := os.Getenv(v); val != "" {
				full = append(full, "--env="+v+"="+val)
			}
		}

		// O processo do host criado pelo flatpak-spawn recebe os file descriptors
		// reais do terminal, mas fica numa sessão nova, sem terminal de controle
		// (não tem /dev/tty). whiptail/ncurses funcionam mesmo assim (usam os fds
		// herdados direto), mas qualquer TUI baseada em Bubbletea — como o `gum`
		// que o ai-cli-uninstaller.sh usa — abre /dev/tty explicitamente pra ler
		// teclado, e isso falha com "no such device or address" sem terminal de
		// controle: o script então recebia erro na primeira interação e voltava
		// na hora. `script -qec "..." /dev/null` roda o comando numa sessão nova
		// com um pty próprio (que ganha terminal de controle de verdade), o que
		// resolve os dois casos — por isso é usado sempre, não só pro gum.
		inner := shellJoin(append([]string{scriptPath}, args...))
		full = append(full, "script", "-qec", inner, "/dev/null")
		return exec.Command("flatpak-spawn", full...)
	}
	return exec.Command(scriptPath, args...)
}

func shellJoin(parts []string) string {
	quoted := make([]string, len(parts))
	for i, p := range parts {
		quoted[i] = "'" + strings.ReplaceAll(p, "'", `'\''`) + "'"
	}
	return strings.Join(quoted, " ")
}
