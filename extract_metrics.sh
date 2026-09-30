#!/usr/bin/env bash

INPUT_FILE=""
SHOW_ATTR=0

# Parsing degli argomenti
for arg in "$@"; do
  case "$arg" in
    -a|--attributes|-d|--details)
      SHOW_ATTR=1
      ;;
    -h|--help)
      echo "Uso: $0 <file_spezzone_log> [-a|--attributes]"
      echo "Opzioni:"
      echo "  -a, --attributes   Mostra l'elenco unico degli attributi per ciascuna metrica"
      exit 0
      ;;
    *)
      if [[ -z "$INPUT_FILE" ]]; then
        INPUT_FILE="$arg"
      fi
      ;;
  esac
done

# Verifica presenza del file
if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "Uso: $0 <file_spezzone_log> [-a|--attributes]"
  echo "Esempio solo nomi: $0 spezzone_1.log"
  echo "Esempio con attributi: $0 spezzone_1.log -a"
  exit 1
fi

if [[ "$SHOW_ATTR" -eq 1 ]]; then
  # Modalità Dettagliata: Metriche + Attributi unici
  awk '
    /^[[:space:]]*[a-zA-Z0-9_\.\-\/]+\{/ {
      line = $0
      metric = line
      sub(/\{.*/, "", metric)
      sub(/^[[:space:]]*/, "", metric)

      attr_str = line
      sub(/^[^{]*\{/, "", attr_str)
      sub(/\}.*/, "", attr_str)

      n = split(attr_str, pairs, ",")
      has_attr = 0
      for (i = 1; i <= n; i++) {
        pair = pairs[i]
        sub(/^[[:space:]]*/, "", pair)
        if (pair ~ /^[a-zA-Z0-9_\.\-]+=/) {
          key = pair
          sub(/=.*/, "", key)
          print metric "|" key
          has_attr = 1
        }
      }
      if (!has_attr) {
        print metric "|"
      }
    }
  ' "$INPUT_FILE" | sort -u | awk -F'|' '
    BEGIN { current_metric = "" }
    {
      metric = $1
      key = $2
      if (metric != current_metric) {
        if (current_metric != "") print ""
        print metric
        current_metric = metric
      }
      if (key != "") {
        print "  - " key
      }
    }
  '
else
  # Modalità Base: Solo nomi metriche
  awk '
    /^[[:space:]]*[a-zA-Z0-9_\.\-\/]+\{/ {
      sub(/\{.*/, "");
      sub(/^[[:space:]]*/, "");
      print;
    }
  ' "$INPUT_FILE" | sort -u
fi