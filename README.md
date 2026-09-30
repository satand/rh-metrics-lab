# RH Otel UWM Lab

## Inoltrare query su app demo

Apri il port-forward verso il service dell'app:
```
oc port-forward svc/sample-otel-app-service 9555:9555 -n app-ns
```
Scaricare lo schema Protobuf del progetto OpenTelemetry Demo:
```
curl -sO https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/main/pb/demo.proto
```

Fai le invocazioni con:
```
grpcurl -plaintext \
  -proto demo.proto \
  -d '{"context_keys": ["phone"]}' \
  localhost:9555 \
  oteldemo.AdService/GetAds
```

## Metriche da osservare

Il contatore delle chiamate totali ricevute:
```
rpc_server_duration_milliseconds_count{service_name="adservice-demo"}
```
La somma totale del tempo impiegato per servire tutte quelle chiamate (in millisecondi):
```
rpc_server_duration_milliseconds_sum{service_name="adservice-demo"}
```
I vari scaglioni di latenza per calcolare i percentili (es. p95, p99):
```
rpc_server_duration_milliseconds_bucket{service_name="adservice-demo"}
```

## I tre livelli delle metriche

```
ResourceMetrics (L'entità che emette)
  └── ScopeMetrics (La libreria di strumentazione)
        └── Metric (Metadati + Tipo + Data Points)
```

Sia la ResourceMetrics che la Metric posseggono attributi specifici. Quando l'exporter prometheus del collector espone le metriche raccolte con il flag resource_to_telemetry_conversion.enabled a false solo gli attributti del livello Metric vengono trasformati in label di ogni metrica; mentre se è settato a true anche gli attributi del livello ResourceMetrics sono convertiti in metric label.

Se resource_to_telemetry_conversion.enabled è settato a false, per associare i metadati Kubernetes alle metriche applicative, in PromQL devi effettuare una group_left join con target_info:
```
rpc_server_duration_milliseconds_count 
* on(job, instance, exported_instance) group_left(k8s_namespace_name, k8s_pod_name) target_info{k8s_namespace_name="app-ns"}
```

Nello stesso exporter prometheus può essere settato without_scope_info: true per disabilitare l'invio di attributi addizionali collegati allo scope OTel (otel_scope_name, otel_scope_version)

# Analisi delle metriche collezionate

Abilitare nella pipeline del collettore l'exporter debug con verbosity normal

Esportare i log del collettore su un file locale:
```
oc logs -n otel-ns <otel-collector-pod-name> --follow > log-raw.log
```

Estrarre uno specifico spezzone dei log usando:
```
./extract_otel_block.sh log-raw.log 1 spezzone_1.log
```

Analisi delle resource all'interno dello spezzone:
```
./extract_resources.sh spezzone_1.log
```

Analisi delle resource all'interno dello spezzone insieme con gli attributi di ciascuna resource
```
./extract_resources.sh spezzone_1.log -a
```

Analisi delle resource all'interno dello spezzone insieme con gli attributi e i loro valori di ciascuna resource
```
./extract_resources.sh spezzone_1.log -v
```

Analisi delle metriche uniche all'interno dello spezzone:
```
./extract_metrics.sh spezzone_1.log
```

Analisi delle metriche uniche all'interno dello spezzone insieme con gli attributi di ciascuna metrica
```
./extract_metrics.sh spezzone_1.log -a
```


## Metriche di monitoring dello UWM

Monitora le serie temporali di prometheus UWM attive (in memoria):
```
prometheus_tsdb_head_series{namespace="openshift-user-workload-monitoring", job="prometheus-user-workload"}
```

