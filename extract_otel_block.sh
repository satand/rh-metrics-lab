#!/usr/bin/env bash

# File di input (primo parametro)
LOG_FILE="${1}"
# Numero dello spezzone da estrarre (1 = il primo, 2 = il secondo, oppure "last" per l'ultimo)
BLOCK_NUM="${2:-1}"
# File di output (terzo parametro)
OUTPUT_FILE="${3:-spezzone_otel.log}"

# Verifica presenza file di log
if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
  echo "Uso: $0 <file_log_input> [numero_spezzone|last] [file_output]"
  echo "Esempio: $0 collector.log 1 spezzone_1.log"
  echo "Esempio: $0 collector.log last ultimo_spezzone.log"
  exit 1
fi

awk -v block="$BLOCK_NUM" '
  BEGIN {
    in_block = 0
    current_block = 0
  }

  # Pattern di INIZIO spezzone (deve contenere "info" e "Metrics {"resource":")
  /info[[:space:]]+Metrics[[:space:]]+\{"resource":/ {
    in_block = 1
    current_block++
  }

  # Accumulo delle righe
  {
    if (in_block) {
      if (block == "last") {
        buffer[current_block] = buffer[current_block] $0 "\n"
      } else if (current_block == block) {
        print $0
      }
    }
  }

  # Pattern di FINE spezzone (la riga JSON finale di chiusura, senza "info")
  /[[:space:]]*\{"resource":.*"otelcol\.signal":[[:space:]]*"metrics"\}/ && !/info/ {
    if (in_block) {
      in_block = 0
      if (block != "last" && current_block == block) {
        exit
      }
    }
  }

  END {
    if (block == "last" && current_block > 0) {
      printf "%s", buffer[current_block]
    }
  }
' "$LOG_FILE" > "$OUTPUT_FILE"

# Verifica se il file estratto è stato generato ed è valido
if [[ -s "$OUTPUT_FILE" ]]; then
  echo "✓ Spezzone estratto con successo in: $OUTPUT_FILE"
else
  echo "✕ Nessuno spezzone trovato per il parametro specificato ($BLOCK_NUM)."
  rm -f "$OUTPUT_FILE"
  exit 1
fi