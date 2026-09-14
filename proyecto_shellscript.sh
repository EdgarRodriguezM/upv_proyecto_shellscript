#!/bin/bash

set -u

CARPETA_BASE="$(cd "$(dirname "$0")" && pwd)"
CARPETA_DATASETS="$CARPETA_BASE/datasets"
CARPETA_INFORMES="$CARPETA_BASE/informes"
CARPETA_HISTORICO="$CARPETA_BASE/historico"
LOG="$CARPETA_BASE/log.txt"

API="https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/"
DIAS_RETENCION=7

FECHA_HORA=$(date '+%Y-%m-%d %H:%M:%S')
MARCA_TIEMPO=$(date '+%Y%m%d_%H%M%S')
FECHA_DIA=$(date '+%Y-%m-%d')

ARCHIVO_JSON="$CARPETA_DATASETS/precios_gasolineras_${MARCA_TIEMPO}.json"
ARCHIVO_TXT="$CARPETA_INFORMES/informe_${MARCA_TIEMPO}.txt"
ARCHIVO_HTML="$CARPETA_INFORMES/informe_${MARCA_TIEMPO}.html"

ARCHIVO_HISTORICO="$CARPETA_HISTORICO/precios_historicos.csv"
TEMP_HISTORICO="$CARPETA_HISTORICO/.precios_historicos.tmp.csv"

mkdir -p "$CARPETA_DATASETS" "$CARPETA_INFORMES" "$CARPETA_HISTORICO"
touch "$LOG"

log() {
    echo "[$FECHA_HORA] $1" | tee -a "$LOG"
}

error() {
    echo "[$FECHA_HORA] ERROR: $1" | tee -a "$LOG" >&2
}

log "Inicio de ejecución."

if ! command -v curl >/dev/null 2>&1; then
    error "curl no está instalado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    error "jq no está instalado."
    exit 1
fi

JSON_PRUEBA="${JSON_PRUEBA:-}"

if [ -n "$JSON_PRUEBA" ]; then
    log "Usando archivo JSON de prueba: $JSON_PRUEBA"
    cp "$JSON_PRUEBA" "$ARCHIVO_JSON"
else
    log "Descargando datos..."
    if ! curl -fsS --retry 2 --connect-timeout 20 --max-time 120 "$API" -o "$ARCHIVO_JSON"; then
        error "No se pudo descargar la API."
        rm -f "$ARCHIVO_JSON"
        exit 1
    fi
fi

if [ ! -s "$ARCHIVO_JSON" ]; then
    error "El JSON descargado está vacío."
    exit 1
fi

if ! jq -e '.ListaEESSPrecio | type == "array"' "$ARCHIVO_JSON" >/dev/null; then
    error "El JSON no contiene ListaEESSPrecio como array."
    exit 1
fi

TOTAL_REGISTROS=$(jq '.ListaEESSPrecio | length' "$ARCHIVO_JSON")

log "Registros de estaciones encontrados: $TOTAL_REGISTROS"
log "Procesando estadísticas..."

readarray -t ESTADISTICAS < <(jq -r '
    def estadisticas($campo; $provincia):
        [
            .ListaEESSPrecio[]
            | select(($provincia == "") or (.["Provincia"] == $provincia))
            | .[$campo]
            | gsub(","; ".")
            | tonumber?
            | select(. != null and . > 0)
        ] as $p
        | if ($p | length) == 0 then
            "N/D|N/D|N/D|0"
          else
            ($p | min) as $min
            | ($p | max) as $max
            | (($p | add) / ($p | length)) as $avg
            | "\($min)|\($max)|\($avg)|\($p | length)"
          end;

    [
        estadisticas("Precio Gasolina 95 E5"; ""),
        estadisticas("Precio Gasolina 98 E5"; ""),
        estadisticas("Precio Gasoleo A"; ""),
        estadisticas("Precio Gasolina 95 E5"; "VALENCIA / VALÈNCIA"),
        estadisticas("Precio Gasolina 98 E5"; "VALENCIA / VALÈNCIA"),
        estadisticas("Precio Gasoleo A"; "VALENCIA / VALÈNCIA"),
        ([.ListaEESSPrecio[] | select(.["Provincia"] == "VALENCIA / VALÈNCIA")] | length | tostring)
    ] | .[]
' "$ARCHIVO_JSON")

G95="${ESTADISTICAS[0]}"
G98="${ESTADISTICAS[1]}"
GA="${ESTADISTICAS[2]}"
V95="${ESTADISTICAS[3]}"
V98="${ESTADISTICAS[4]}"
VA="${ESTADISTICAS[5]}"
TOTAL_VALENCIA="${ESTADISTICAS[6]}"

IFS='|' read -r G95_MIN G95_MAX G95_AVG G95_N <<< "$G95"
IFS='|' read -r G98_MIN G98_MAX G98_AVG G98_N <<< "$G98"
IFS='|' read -r GA_MIN GA_MAX GA_AVG GA_N <<< "$GA"

IFS='|' read -r V95_MIN V95_MAX V95_AVG V95_N <<< "$V95"
IFS='|' read -r V98_MIN V98_MAX V98_AVG V98_N <<< "$V98"
IFS='|' read -r VA_MIN VA_MAX VA_AVG VA_N <<< "$VA"

log "Gasolina 95 E5: $G95_N precios válidos."
log "Gasolina 98 E5: $G98_N precios válidos."
log "Gasóleo A: $GA_N precios válidos."
log "Registros de Valencia: $TOTAL_VALENCIA"

# ============================================================
# HISTÓRICO
# ============================================================

HEADER_NUEVO="fecha,IDEESS,provincia,municipio,rotulo,direccion,gasolina95,gasolina98,gasoleoA,latitud,longitud"

if [ ! -f "$ARCHIVO_HISTORICO" ]; then
    echo "$HEADER_NUEVO" > "$ARCHIVO_HISTORICO"
fi

jq -r --arg fecha "$FECHA_DIA" '
    .ListaEESSPrecio[]
    | [
        $fecha,
        (.["IDEESS"] // ""),
        (.["Provincia"] // ""),
        (.["Municipio"] // ""),
        (.["Rótulo"] // ""),
        (.["Dirección"] // ""),
        (.["Precio Gasolina 95 E5"] // ""),
        (.["Precio Gasolina 98 E5"] // ""),
        (.["Precio Gasoleo A"] // ""),
        (.["Latitud"] // ""),
        (.["Longitud (WGS84)"] // "")
      ]
    | @csv
' "$ARCHIVO_JSON" > "$TEMP_HISTORICO"

if [ ! -s "$TEMP_HISTORICO" ]; then
    error "No se pudieron generar las filas del histórico."
    rm -f "$TEMP_HISTORICO"
    exit 1
fi

{
    echo "$HEADER_NUEVO"
    tail -n +2 "$ARCHIVO_HISTORICO"
    cat "$TEMP_HISTORICO"
} |
awk -F',' '
    NR == 1 {
        header = $0
        next
    }

    {
        # La clave usa los dos primeros campos del CSV: fecha + IDEESS.
        # Las comas que puedan aparecer en otros campos no afectan a $0,
        # que conserva la fila completa exactamente como fue generada.
        key = $1 SUBSEP $2
        rows[key] = $0

        if (!(key in first_order)) {
            first_order[key] = ++n
            order[n] = key
        }
    }

    END {
        print header

        for (i = 1; i <= n; i++) {
            print rows[order[i]]
        }
    }
' > "$ARCHIVO_HISTORICO.tmp"

mv "$ARCHIVO_HISTORICO.tmp" "$ARCHIVO_HISTORICO"
rm -f "$TEMP_HISTORICO"

log "Histórico actualizado: $ARCHIVO_HISTORICO"

# ============================================================
# TXT
# ============================================================

{
    echo "INFORME DE PRECIOS DE CARBURANTES"
    echo "Fecha de ejecución: $FECHA_HORA"
    echo
    echo "========================================"
    echo "RESUMEN GENERAL"
    echo "========================================"
    echo "Registros de estaciones: $TOTAL_REGISTROS"
    echo
    echo "Gasolina 95 E5"
    echo "  Mínimo: $G95_MIN €/L"
    echo "  Máximo: $G95_MAX €/L"
    echo "  Media:  $G95_AVG €/L"
    echo "  Precios válidos: $G95_N"
    echo
    echo "Gasolina 98 E5"
    echo "  Mínimo: $G98_MIN €/L"
    echo "  Máximo: $G98_MAX €/L"
    echo "  Media:  $G98_AVG €/L"
    echo "  Precios válidos: $G98_N"
    echo
    echo "Gasóleo A"
    echo "  Mínimo: $GA_MIN €/L"
    echo "  Máximo: $GA_MAX €/L"
    echo "  Media:  $GA_AVG €/L"
    echo "  Precios válidos: $GA_N"
    echo
    echo "========================================"
    echo "VALENCIA / VALÈNCIA"
    echo "========================================"
    echo "Estaciones: $TOTAL_VALENCIA"
    echo
    echo "Gasolina 95 E5"
    echo "  Mínimo: $V95_MIN €/L"
    echo "  Máximo: $V95_MAX €/L"
    echo "  Media:  $V95_AVG €/L"
    echo "  Precios válidos: $V95_N"
    echo
    echo "Gasolina 98 E5"
    echo "  Mínimo: $V98_MIN €/L"
    echo "  Máximo: $V98_MAX €/L"
    echo "  Media:  $V98_AVG €/L"
    echo "  Precios válidos: $V98_N"
    echo
    echo "Gasóleo A"
    echo "  Mínimo: $VA_MIN €/L"
    echo "  Máximo: $VA_MAX €/L"
    echo "  Media:  $VA_AVG €/L"
    echo "  Precios válidos: $VA_N"
} > "$ARCHIVO_TXT"

# ============================================================
# HTML
# ============================================================

cat > "$ARCHIVO_HTML" <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Informe de carburantes</title>
<style>
body{font-family:Arial,sans-serif;background:#f4f6f8;color:#1f2937;max-width:1000px;margin:30px auto;padding:0 20px}
.card{background:#fff;border-radius:12px;padding:20px;margin-bottom:16px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
h1,h2{margin-top:0}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:10px;border-bottom:1px solid #e5e7eb}
</style>
</head>
<body>
<div class="card">
<h1>Informe de precios de carburantes</h1>
<p><strong>Fecha:</strong> $FECHA_HORA</p>
<p><strong>Estaciones:</strong> $TOTAL_REGISTROS</p>
</div>

<div class="card">
<h2>Resumen general</h2>
<table>
<tr><th>Carburante</th><th>Mínimo</th><th>Media</th><th>Máximo</th><th>Válidos</th></tr>
<tr><td>Gasolina 95 E5</td><td>$G95_MIN €/L</td><td>$G95_AVG €/L</td><td>$G95_MAX €/L</td><td>$G95_N</td></tr>
<tr><td>Gasolina 98 E5</td><td>$G98_MIN €/L</td><td>$G98_AVG €/L</td><td>$G98_MAX €/L</td><td>$G98_N</td></tr>
<tr><td>Gasóleo A</td><td>$GA_MIN €/L</td><td>$GA_AVG €/L</td><td>$GA_MAX €/L</td><td>$GA_N</td></tr>
</table>
</div>

<div class="card">
<h2>Valencia / València</h2>
<p><strong>Estaciones:</strong> $TOTAL_VALENCIA</p>
<table>
<tr><th>Carburante</th><th>Mínimo</th><th>Media</th><th>Máximo</th><th>Válidos</th></tr>
<tr><td>Gasolina 95 E5</td><td>$V95_MIN €/L</td><td>$V95_AVG €/L</td><td>$V95_MAX €/L</td><td>$V95_N</td></tr>
<tr><td>Gasolina 98 E5</td><td>$V98_MIN €/L</td><td>$V98_AVG €/L</td><td>$V98_MAX €/L</td><td>$V98_N</td></tr>
<tr><td>Gasóleo A</td><td>$VA_MIN €/L</td><td>$VA_AVG €/L</td><td>$VA_MAX €/L</td><td>$VA_N</td></tr>
</table>
</div>
</body>
</html>
EOF

log "Eliminando datasets con más de 7 días..."

find "$CARPETA_DATASETS" -type f -name 'precios_gasolineras_*.json' -mtime +"$DIAS_RETENCION" -print -delete >> "$LOG" 2>&1

log "Informes generados: $(basename "$ARCHIVO_TXT") y $(basename "$ARCHIVO_HTML")"
log "Ejecución finalizada correctamente."
exit 0
