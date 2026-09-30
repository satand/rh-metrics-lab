#!/usr/bin/env bash

INPUT_FILE=""
MODE="default"

# Parsing degli argomenti
for arg in "$@"; do
  case "$arg" in
    -a|--attributes|-d|--details)
      MODE="attributes"
      ;;
    -v|--values)
      MODE="values"
      ;;
    -h|--help)
      echo "Uso: $0 <file_spezzone_log> [-a|--attributes] [-v|--values]"
      echo "Opzioni:"
      echo "  -a, --attributes   Mostra l'elenco delle chiavi degli attributi per ciascuna risorsa"
      echo "  -v, --values       Mostra chiavi e valori completi degli attributi per ciascuna risorsa"
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
  echo "Uso: $0 <file_spezzone_log> [-a|--attributes] [-v|--values]"
  echo "Esempio solo risorse:   $0 spezzone_1.log"
  echo "Esempio con attributi: $0 spezzone_1.log -a"
  echo "Esempio con valori:    $0 spezzone_1.log -v"
  exit 1
fi

# 1. Parsing ed estrazione iniziale delle risorse (compatibile POSIX / macOS / Linux)
PARSED_DATA=$(awk '
  /ResourceMetrics/ {
    line = $0
    
    # Identificatore ResourceMetrics (es. ResourceMetrics #0)
    res_label = ""
    if (match(line, /ResourceMetrics[[:space:]]+#[0-9]+/)) {
      res_label = substr(line, RSTART, RLENGTH)
    } else {
      res_label = "ResourceMetrics"
    }

    # Rimuove il prefisso fino allo schema URL o all inizio degli attributi
    attr_str = line
    sub(/^.*ResourceMetrics #[0-9]+([[:space:]]+\[[^\]]*\])?[[:space:]]*/, "", attr_str)

    curr_key = ""
    svc_name = ""
    pod_name = ""
    inst_id = ""
    
    temp = attr_str
    while (match(temp, /[a-zA-Z0-9_\.\-]+=/)) {
      if (curr_key != "") {
        val = substr(temp, 1, RSTART - 1)
        sub(/[[:space:]]+$/, "", val)
        if (curr_key == "service.name") svc_name = val
        if (curr_key == "k8s.pod.name") pod_name = val
        if (curr_key == "service.instance.id") inst_id = val
        print res_label "|" curr_key "|" val
      }
      curr_key = substr(temp, RSTART, RLENGTH - 1)
      temp = substr(temp, RSTART + RLENGTH)
    }
    if (curr_key != "") {
      val = temp
      sub(/[[:space:]]+$/, "", val)
      if (curr_key == "service.name") svc_name = val
      if (curr_key == "k8s.pod.name") pod_name = val
      if (curr_key == "service.instance.id") inst_id = val
      print res_label "|" curr_key "|" val
    }

    # Costruisce l intestazione sintetica
    summary = ""
    if (svc_name != "") summary = "service.name=" svc_name
    if (pod_name != "") {
      if (summary != "") summary = summary ", "
      summary = summary "k8s.pod.name=" pod_name
    } else if (inst_id != "") {
      if (summary != "") summary = summary ", "
      summary = summary "service.instance.id=" inst_id
    }
    
    if (summary != "") {
      print res_label " (" summary ")|__HEADER__|"
    } else {
      print res_label "|__HEADER__|"
    }
  }
' "$INPUT_FILE")

# 2. Formattazione dell'output in base alla modalità scelta
if [[ "$MODE" == "default" ]]; then
  echo "$PARSED_DATA" | awk -F'|' '$2 == "__HEADER__" { print $1 }' | sort -u
elif [[ "$MODE" == "attributes" ]]; then
  echo "$PARSED_DATA" | awk -F'|' '
    $2 == "__HEADER__" {
      header[$1] = $1
      next
    }
    {
      res = $1
      key = $2
      if (key != "") {
        attr_list[res "|" key] = 1
      }
    }
    END {
      for (res_line in header) {
        print res_line
        split(res_line, parts, " ")
        res_id = parts[1] " " parts[2]
        
        n = 0
        delete keys_array
        for (rk in attr_list) {
          split(rk, rk_parts, "|")
          if (rk_parts[1] == res_id) {
            n++
            keys_array[n] = rk_parts[2]
          }
        }
        for (i = 1; i <= n; i++) {
          for (j = i + 1; j <= n; j++) {
            if (keys_array[i] > keys_array[j]) {
              tmp = keys_array[i]
              keys_array[i] = keys_array[j]
              keys_array[j] = tmp
            }
          }
        }
        for (i = 1; i <= n; i++) {
          print "  - " keys_array[i]
        }
        print ""
      }
    }
  '
elif [[ "$MODE" == "values" ]]; then
  echo "$PARSED_DATA" | awk -F'|' '
    $2 == "__HEADER__" {
      header[$1] = $1
      next
    }
    {
      res = $1
      key = $2
      val = $3
      if (key != "") {
        attr_val_list[res "|" key] = val
      }
    }
    END {
      for (res_line in header) {
        print res_line
        split(res_line, parts, " ")
        res_id = parts[1] " " parts[2]
        
        n = 0
        delete keys_array
        for (rk in attr_val_list) {
          split(rk, rk_parts, "|")
          if (rk_parts[1] == res_id) {
            n++
            keys_array[n] = rk_parts[2]
          }
        }
        for (i = 1; i <= n; i++) {
          for (j = i + 1; j <= n; j++) {
            if (keys_array[i] > keys_array[j]) {
              tmp = keys_array[i]
              keys_array[i] = keys_array[j]
              keys_array[j] = tmp
            }
          }
        }
        for (i = 1; i <= n; i++) {
          k = keys_array[i]
          v = attr_val_list[res_id "|" k]
          print "  - " k " = " v
        }
        print ""
      }
    }
  '
fi