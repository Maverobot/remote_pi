#!/usr/bin/env bash
set -euo pipefail

# Despacha uma tarefa orquestrada pra um dos panes de agente do workspace
# cmux atual. Sempre prefixa o prompt com [ORCH:<task-id>] — esse é o gatilho
# que faz os 4 CLAUDE.md de subprojeto lerem .orchestration/INSTRUCTIONS.md
# e aplicarem as regras de modo orquestrado (cwd-only, sem commit, etc).
#
# Uso:
#   scripts/cmux-dispatch.sh [--wait [--timeout <s>]] <Pane> <task-id> <prompt>
#
# Exemplos:
#   scripts/cmux-dispatch.sh Extension 03-ts-codec "Implemente passo 3 do plan/03-protocol.md"
#   scripts/cmux-dispatch.sh --wait Extension 03-ts-codec "Implemente..."
#
# Argumentos:
#   --wait              (opcional) bloqueia até receber `agent.hook.Stop`
#                       (phase=completed) com payload.cwd matching o pane alvo.
#                       Requer que o worker tenha sido lançado via
#                       `cmux claude-teams` (cmux-bootstrap-agents.sh já faz isso).
#   --timeout <s>       (opcional, default 1800) timeout em segundos pro --wait
#   <Pane>              App | Relay | Extension | Site
#   <task-id>           ID curto (kebab/snake: a-z 0-9 . _ -)
#   <prompt>            texto do prompt (use aspas se tem espaços)
#
# Pra conversa fora do protocolo orquestrado (perguntas exploratórias,
# debug, retomar claude), use `cmux send` direto. Esse script é
# exclusivamente pro modo orquestrado — ele EXISTE pra não esquecer o
# marker.

usage() {
  awk '
    /^# Despacha/ { on = 1 }
    on {
      if (!/^#/) exit
      sub(/^# /, "")
      sub(/^#$/, "")
      print
    }
  ' "$0"
}

wait_flag=0
wait_timeout=1800

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --wait)       wait_flag=1; shift ;;
    --timeout)    wait_timeout="${2:-}"; shift 2 || { echo "erro: --timeout precisa de valor" >&2; exit 2; } ;;
    --)           shift; break ;;
    -*)           echo "erro: flag desconhecida: $1" >&2; usage >&2; exit 2 ;;
    *)            break ;;
  esac
done

if [ $# -lt 3 ]; then
  usage >&2
  echo >&2
  echo "erro: argumentos insuficientes (esperado 3 posicionais, recebido $#)" >&2
  exit 2
fi

pane="$1"
task_id="$2"
shift 2
prompt="$*"

valid_panes=(App Relay Extension Site)
case " ${valid_panes[*]} " in
  *" $pane "*) ;;
  *)
    echo "erro: pane '$pane' inválido. Use: ${valid_panes[*]}" >&2
    exit 2
    ;;
esac

if [[ ! "$task_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "erro: task-id '$task_id' inválido (use a-z A-Z 0-9 . _ -)" >&2
  exit 2
fi

if [ -z "$prompt" ]; then
  echo "erro: prompt vazio" >&2
  exit 2
fi

command -v cmux >/dev/null || { echo "erro: cmux não encontrado no PATH" >&2; exit 1; }

WS_REF=$(cmux identify 2>/dev/null \
  | awk -F'"' '/"workspace_ref"/ {print $4; exit}')
[ -n "$WS_REF" ] || { echo "erro: workspace cmux não identificado" >&2; exit 1; }

# resolve surface ID pelo título do pane no workspace alvo
sid=$(cmux tree 2>/dev/null | awk -v target="$WS_REF" -v name="$pane" '
  /workspace workspace:/ {
    in_ws = 0
    for (i = 1; i <= NF; i++) if ($i == target) in_ws = 1
    next
  }
  in_ws && /surface surface:/ && index($0, "\"" name "\"") {
    for (i = 1; i <= NF; i++) if ($i ~ /^surface:/) { print $i; exit }
  }
')

if [ -z "$sid" ]; then
  echo "erro: pane '$pane' não encontrado no workspace $WS_REF" >&2
  echo "rode scripts/cmux-bootstrap-agents.sh pra criar os 4 panes" >&2
  exit 3
fi

full_prompt="[ORCH:${task_id}] ${prompt}"

cmux send     --surface "$sid" -- "$full_prompt" >/dev/null

# Pequena pausa pro TUI do claude no destino terminar de processar o paste
# antes do Enter chegar — sem isso, prompts grandes (>2KB) racing com o
# bracketed-paste mode fazem o Enter virar newline no buffer em vez de
# submit. Sintoma: prompt fica grudado na caixa de texto, "pula linha".
sleep 0.4

cmux send-key --surface "$sid" enter >/dev/null

printf "ok  %-10s %s\n     [ORCH:%s] %s\n" "$pane" "$sid" "$task_id" "$prompt"

if [ "$wait_flag" -eq 1 ]; then
  # Mapeia título do pane → cwd do subprojeto pra filtrar o evento certo
  # (cmux events não filtra por workspace, só por categoria/nome — desambig
  # pelo payload.cwd e payload.phase=="completed").
  case "$pane" in
    App)        sub="app" ;;
    Relay)      sub="relay" ;;
    Extension)  sub="pi-extension" ;;
    Site)       sub="site" ;;
  esac
  REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  expected_cwd="$REPO_ROOT/$sub"

  command -v jq >/dev/null || { echo "erro: jq não encontrado (necessário pra --wait)" >&2; exit 1; }

  cursor_dir="$HOME/.orch"
  mkdir -p "$cursor_dir"
  cursor_file="$cursor_dir/cursor.seq"

  echo "aguardando agent.hook.Stop (phase=completed, cwd=$expected_cwd) — timeout ${wait_timeout}s..." >&2

  # cmux events bloqueia até receber. Pipe via jq pra filtrar pelo cwd
  # + phase=completed; head -n 1 fecha o pipe ao primeiro match.
  # `timeout` envolve o conjunto pra prevenir hang infinito.
  set +e
  timeout "$wait_timeout" bash -c '
    cmux events --category agent --name agent.hook.Stop \
                --reconnect --no-heartbeat --no-ack \
                --cursor-file '"'$cursor_file'"' \
      | jq -c --arg cwd '"'$expected_cwd'"' '\''
          select(.payload.phase == "completed" and .payload.cwd == $cwd)
        '\'' \
      | head -n 1
  '
  rc=$?
  set -e

  if [ "$rc" -eq 124 ]; then
    echo "timeout (${wait_timeout}s) sem receber Stop pra $pane" >&2
    exit 4
  fi
  if [ "$rc" -ne 0 ]; then
    echo "erro inesperado escutando eventos (rc=$rc)" >&2
    exit "$rc"
  fi
  echo "ok  $pane completou (Stop recebido)" >&2
fi
