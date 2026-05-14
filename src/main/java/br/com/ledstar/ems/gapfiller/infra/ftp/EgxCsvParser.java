package br.com.ledstar.ems.gapfiller.infra.ftp;

import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import com.opencsv.CSVParser;
import com.opencsv.CSVParserBuilder;
import com.opencsv.CSVReader;
import com.opencsv.CSVReaderBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.io.ByteArrayInputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.text.DecimalFormat;
import java.text.DecimalFormatSymbols;
import java.text.NumberFormat;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Parser do CSV exportado pelo Schneider EGX300.
 *
 * Estrutura REAL confirmada pelos exports baixados do gateway BM 10.193.217.11
 * (arquivos MV-F3-1_2 / MV-F3-4_5, ~11400 linhas / ~39 dias, 11/05/2026):
 *
 *   L1: Gateway Name | Gateway SN | Gateway IP Address | Gateway MAC | Device Name | Device Local ID | Device Type ID | Device Type Name | Logging Interval | Historical Intervals
 *   L2: BM | 53107597 | 10.193.217.11 | 00:80:67:86:3A:73 | MV-F3-1 | 2 | 10002 | GIPAM FI | 0 | 0
 *   L3: (vazia)
 *   L4: ... | Topic ID1 | Topic ID2 | ... | Topic ID15
 *   L5: ... | 1018 | 1019 | ... | 1621 | 1625        (codigos internos por coluna)
 *   L6: (vazia)
 *   L7: Error | UTC Offset (minutes) | Local Time Stamp | Voltage A-N | Voltage B-N | Voltage C-N | Voltage A-B | Voltage B-C | Voltage C-A | Current A | Current B | Current C | Frequency | Real Power Total (kW) | Reactive Power Total (kVAR) | Power Factor Sign | Real Energy (kWh) | Reactive Energy (kVARh)
 *   L8+: 0 | -240 | 18/03/2026 19:00:00 | 7969.058 | ... | 16878047232000 | 4109592320000
 *
 * Particularidades aprendidas com os dados reais:
 *   - 18 colunas; header NA LINHA 7 (detectada dinamicamente por "Error" + "Local Time Stamp" + coluna "(kWh)")
 *   - Timestamp local Manaus, formato dd/MM/yyyy HH:mm[:ss] (segundos presentes nas linhas pos-wrap)
 *   - UTC Offset = -240 (minutos) = -4h = America/Manaus -> worker NAO converte TZ
 *   - "Real Energy (kWh)" / "Reactive Energy (kVARh)" sao ACUMULADORES MONOTONICOS (~1e12-1e14, escala bruta do gateway)
 *   - O .csv do FTP e um BUFFER CIRCULAR (~101 KB) que envolve (wrap) -> ~0.5% das linhas sao LIXO:
 *       timestamps absurdos (1996, 2013, 2030...), valores ~1e17..1e67, Error em codigos altos.
 *     Estas linhas SAO FILTRADAS aqui antes de qualquer leitura sair do parser
 *     (year fora de [2020, anoAtual+1] OU valor nao-finito / negativo / > 1e15).
 *     Error == 1 NAO e filtrado (e erro de comunicacao recuperavel - a leitura vem boa).
 *
 * Pendencias (precisam do CSV cru do FTP e/ou do DB pra fechar):
 *   - Formato exato dos numeros no .csv cru (este parser tolera "16878047232000",
 *     "7969.058" e "7.728.264.704.000,00" - US-decimal/plain e BR-grouping)
 *   - Strings de valuetype reais no DB (SELECT DISTINCT sdr_valuetype WHERE sdr_sensor=<id>)
 *     antes de habilitar a extracao das outras 14 colunas - hoje so a coluna
 *     "Real Energy (kWh)" e lida (-> valuetype KWH; a do incidente da causa-raiz);
 *     {@link #inferValueType(String)} ja cobre o mapeamento das demais (V_L1_N..PF_SYS)
 *     pra quando essa extracao for ligada
 *   - Unidade/escala das colunas de potencia (Real Power vem em ~1e6 x kW) vs o que o DB armazena
 */
@Component
public class EgxCsvParser {

    private static final Logger log = LoggerFactory.getLogger(EgxCsvParser.class);

    /**
     * Dois formatos coexistem no mundo real:
     *  - BR  "dd/MM/yyyy HH:mm[:ss]" - exports XLSX/CSV abertos pelo cliente (locale pt-BR no Excel)
     *  - ISO "yyyy-MM-dd HH:mm[:ss]" - .csv CRU baixado direto do FTP do gateway EGX300
     * O parser tenta ISO primeiro (e o que aparece no FTP, caso real do servico) e cai pro BR
     * (caso reproduzido pelos exports do cliente). Confirmado pelo CSV-HEAD-SAMPLE em prod 13/05/2026.
     */
    private static final DateTimeFormatter TIMESTAMP_FMT_ISO =
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm[:ss]");
    private static final DateTimeFormatter TIMESTAMP_FMT_BR =
        DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm[:ss]");

    static LocalDateTime parseTimestamp(String s) {
        try { return LocalDateTime.parse(s, TIMESTAMP_FMT_ISO); }
        catch (Exception ignored) { return LocalDateTime.parse(s, TIMESTAMP_FMT_BR); }
    }

    /**
     * Acima disto e lixo do wrap do buffer. Acumuladores reais ficam ~1e12-1e14;
     * o menor valor-lixo observado nos exports reais foi ~2.8e17 -> 1e16 e teto
     * seguro (headroom de >100x sobre o legitimo, ainda pega todo o lixo).
     */
    private static final double MAX_PLAUSIBLE_VALUE = 1e16;

    /**
     * (r7, 14/05/2026) Override de divisor por sensor_id. Calibrado lendo a magnitude real
     * de {@code mqtt.sensordatarecord.sdr_value} no banco prd em 14/05:
     * <ul>
     *   <li>{@code 30} (Main Relay Factory BM, MAC 3A:73 slave 1): KWH banco ~1,58e11
     *       → raw ~1,58e14 ÷ <b>1.000</b></li>
     *   <li>{@code 10109} (Trafo 1 F3 Sub-BM, MAC 3A:73 slave 2): KWH banco ~1,7e10
     *       → ÷ <b>1.000</b> (mesma escala do sensor 30)</li>
     *   <li>{@code 21, 10105, 10110, 10111, 10112, 10154}: KWH banco em escala MWh
     *       (~3e4 a 8e7) → ÷ <b>1.000.000</b> (regra GIPAM default)</li>
     * </ul>
     * Override prevalece sobre {@code deviceTypeName} (cobre o caso real dos outliers
     * onde a metadata L1/L2 do CSV não chegou e o gap-filler antes do r7 gravava RAW puro).
     * Sensores fora deste mapa caem na regra antiga do r6.
     */
    static final Map<Long, Double> SENSOR_KWH_DIVISOR = Map.of(
        21L,    1_000_000.0,
        30L,    1_000.0,
        10105L, 1_000_000.0,
        10109L, 1_000.0,
        10110L, 1_000_000.0,
        10111L, 1_000_000.0,
        10112L, 1_000_000.0,
        10154L, 1_000_000.0
    );

    /**
     * (r7) KWH/KVARH/KVAH são acumuladores monotônicos crescentes. Um valor que retroceda
     * mais do que esta fração indica leitura RAW out-of-order escapou ou linha do wrap
     * com dado corrompido. Resets legítimos de medidor são raros e tipicamente vão pra 0,
     * então cobre tanto reset (cai >99% → filtra junto) quanto wrap (cai 20-80%).
     * Caso 0%-1% fica como ruído tolerado.
     */
    private static final double KWH_RETROCESSO_MAX = 0.01;

    private static final NumberFormat BR_FORMAT = mkBrFormat();
    private static NumberFormat mkBrFormat() {
        DecimalFormatSymbols sym = new DecimalFormatSymbols(new Locale("pt", "BR"));
        sym.setDecimalSeparator(',');
        sym.setGroupingSeparator('.');
        DecimalFormat fmt = new DecimalFormat("#,##0.###", sym);
        fmt.setParseBigDecimal(false);
        return fmt;
    }

    public List<SensorReading> parse(SensorMeter meter, byte[] csvBytes,
                                     LocalDateTime windowStart, LocalDateTime windowEnd) {
        for (char sep : new char[]{',', ';', '\t'}) {
            try {
                List<SensorReading> result = parseWith(meter, csvBytes, sep, windowStart, windowEnd);
                if (!result.isEmpty()) {
                    log.info("CSV parser sep='{}' produziu {} leituras validas (sensor={})",
                        sep == '\t' ? "TAB" : sep, result.size(), meter.senId());
                    return result;
                }
            } catch (Exception ex) {
                log.debug("parser sep='{}' falhou: {}", sep, ex.getMessage());
            }
        }
        log.warn("nao consegui parsear CSV do sensor={} ({} bytes)", meter.senId(), csvBytes.length);
        logHeadSample(meter, csvBytes);
        return List.of();
    }

    /**
     * Quando o parse falha (nenhuma leitura saiu apos tentar todos os separadores), loga os primeiros
     * ~1500 bytes do CSV em ASCII printable + escape pra ajudar a adaptar o parser ao formato real.
     * Newlines viram '\n|' (separador visual), nao-imprimiveis viram '\xHH'. Cabe numa linha de log.
     */
    private void logHeadSample(SensorMeter meter, byte[] bytes) {
        int n = Math.min(1500, bytes.length);
        StringBuilder sb = new StringBuilder(n + 200);
        for (int i = 0; i < n; i++) {
            int b = bytes[i] & 0xFF;
            if (b == 0x0D) sb.append("\\r");
            else if (b == 0x0A) sb.append("\\n|");
            else if (b == 0x09) sb.append("\\t");
            else if (b >= 0x20 && b < 0x7F) sb.append((char) b);
            else sb.append(String.format("\\x%02X", b));
        }
        log.warn("CSV-HEAD-SAMPLE sensor={} bytes={} head[0..{}]: {}",
            meter.senId(), bytes.length, n, sb);
    }

    private List<SensorReading> parseWith(SensorMeter meter, byte[] csvBytes, char sep,
                                          LocalDateTime windowStart, LocalDateTime windowEnd) throws Exception {
        CSVParser csvParser = new CSVParserBuilder()
            .withSeparator(sep)
            .withQuoteChar('"')
            .withIgnoreQuotations(false)
            .build();

        try (CSVReader reader = new CSVReaderBuilder(
                new InputStreamReader(new ByteArrayInputStream(csvBytes), StandardCharsets.UTF_8))
                .withCSVParser(csvParser)
                .build()) {

            // (r6) ANTES do header de dados o EGX300 emite 2 linhas com metadata do device:
            //   L1: Gateway Name, Gateway SN, Gateway IP, Gateway MAC, Device Name, ..., Device Type Name, ...
            //   L2: BM,           53107597,   10.193..., 00:80...,    MV-F3-1,     ..., GIPAM FI,         ...
            // Capturamos "Device Type Name" e "Gateway MAC Address" pra replicar a regra de escala do
            // deconsysmodbus.EnergyDeviceFileProcessor#processRecords (divisor /1M ou /1000 conforme device).
            // OBS: a captura eh OPORTUNISTICA — se o CSV nao tem essas linhas (CSVs sinteticos/testes),
            // deviceTypeName fica vazio e applyDeviceScale vira no-op (passa raw).
            String deviceTypeName = "";
            String gatewayMac = "";
            String[] firstSeenRow = null;       // se candidata a L1 (header de metadata), guarda
            boolean metaRowProcessed = false;

            // Header dinamico: a linha que tem "Error" + "Local Time Stamp" + uma coluna "(kWh)"/"Real Energy"
            String[] header = null;
            int dataValueColIdx = -1, timestampColIdx = -1, errorColIdx = -1, utcOffsetColIdx = -1;
            String[] row;
            while ((row = reader.readNext()) != null) {
                int hits = 0;
                for (int i = 0; i < row.length; i++) {
                    String c = row[i] == null ? "" : row[i].trim();
                    String lc = c.toLowerCase(Locale.ROOT);
                    if (lc.equals("local time stamp"))                       { timestampColIdx = i; hits++; }
                    else if (lc.equals("error"))                             { errorColIdx = i; hits++; }
                    else if (lc.startsWith("utc offset"))                    { utcOffsetColIdx = i; hits++; }
                    else if (lc.contains("(kwh)") || lc.contains("real energy")) { dataValueColIdx = i; hits++; }
                }
                if (hits >= 3 && timestampColIdx >= 0 && dataValueColIdx >= 0) {
                    header = row;
                    break;
                }

                // Nao eh header — pode ser uma das 2 primeiras linhas de metadata do EGX300.
                // L1 (column-headers de metadata) detectada por ter "Gateway Name"/"Device Type Name"
                // como celula. L2 (valores) eh a IMEDIATAMENTE seguinte a essa L1.
                if (firstSeenRow == null) {
                    for (String cell : row) {
                        if (cell == null) continue;
                        String lc = cell.trim().toLowerCase(Locale.ROOT);
                        if (lc.equals("device type name") || lc.contains("mac address")
                                || lc.equals("gateway name")) {
                            firstSeenRow = row;
                            break;
                        }
                    }
                } else if (!metaRowProcessed) {
                    // mapeia o valor de "Device Type Name" e "Gateway MAC Address" via firstSeenRow
                    for (int i = 0; i < firstSeenRow.length && i < row.length; i++) {
                        String h = firstSeenRow[i] == null ? "" : firstSeenRow[i].trim().toLowerCase(Locale.ROOT);
                        String v = row[i] == null ? "" : row[i].trim();
                        if (h.equals("device type name") && !v.isEmpty()) deviceTypeName = v;
                        else if (h.contains("mac address")  && !v.isEmpty()) gatewayMac = v;
                    }
                    metaRowProcessed = true;
                }
            }
            if (header == null) return List.of();

            log.debug("header: tsCol={} valCol={} errCol={} utcCol={} ('{}')  device='{}' mac='{}'",
                timestampColIdx, dataValueColIdx, errorColIdx, utcOffsetColIdx,
                header[dataValueColIdx], deviceTypeName, gatewayMac);
            String valueType = inferValueType(header[dataValueColIdx]);
            int minCols = Math.max(Math.max(timestampColIdx, dataValueColIdx), errorColIdx) + 1;

            List<SensorReading> readings = new ArrayList<>();
            int skippedGarbage = 0, skippedWindow = 0, skippedOutOfOrder = 0, skippedRetreating = 0;
            // (r7) Bug 1: estado de monotonia pra detectar linhas RAW out-of-order escapando do wrap
            // do buffer circular. Mantém o último timestamp e o último valor de acumulador energético
            // (KWH/KVARH/KVAH) pra rejeitar leituras que andem pra trás.
            LocalDateTime lastValidTs = null;
            double lastValidEnergyValue = Double.NEGATIVE_INFINITY;
            boolean isEnergyAccumulator =
                "KWH".equals(valueType) || "KVARH".equals(valueType) || "KVAH".equals(valueType);

            while ((row = reader.readNext()) != null) {
                if (row.length < minCols) continue;

                String tsStr  = trimAt(row, timestampColIdx);
                String valStr = trimAt(row, dataValueColIdx);
                if (tsStr.isEmpty() || valStr.isEmpty()) continue;

                LocalDateTime ts;
                try { ts = parseTimestamp(tsStr); }
                catch (Exception ex) { skippedGarbage++; continue; }            // timestamp ilegivel = lixo do wrap

                double value;
                try { value = parseNumber(valStr); }
                catch (Exception ex) { skippedGarbage++; continue; }

                if (!isPlausible(ts, value)) { skippedGarbage++; continue; }    // lixo do wrap (year/valor absurdo)
                if (windowStart != null && ts.isBefore(windowStart)) { skippedWindow++; continue; }
                if (windowEnd   != null && ts.isAfter(windowEnd))    { skippedWindow++; continue; }

                // (r7) Bug 1: filtro de monotonia. Linhas com timestamp retrocedendo OU acumulador
                // de energia retrocedendo > 1% são lixo do wrap "sutil" (year/mês/dia certos, só a
                // hora pula pra trás — não pegado pelo isPlausible). Reportado pelo Cesar 14/05:
                // CSV mostra 10:40 -> 4:57 -> 10:50 e o backend gravava com timestamp errado, gerando
                // delta negativo na curva.
                if (lastValidTs != null && ts.isBefore(lastValidTs)) {
                    skippedOutOfOrder++;
                    continue;
                }
                if (isEnergyAccumulator && lastValidEnergyValue > 0
                        && value < lastValidEnergyValue * (1.0 - KWH_RETROCESSO_MAX)) {
                    // KWH/KVARH/KVAH acumuladores: queda > 1% indica RAW out-of-order ou wrap.
                    // Reset legítimo de medidor (cai pra 0) também é filtrado — perda aceitável,
                    // resets em prod são raros e o RECENT cron rederiva a curva no próximo ciclo.
                    skippedRetreating++;
                    continue;
                }

                // (r7) aplica a regra de escala: override por sensor_id (calibrado em prod 14/05)
                // tem prioridade; senão cai na regra r6 (GIPAM/GIMAC + exceção FAB2 MAIN).
                double finalValue = applyDeviceScale(value, valueType, deviceTypeName, gatewayMac,
                                                     meter.modbusSlaveId(), meter.senId());
                readings.add(new SensorReading(meter.senId(), ts, valueType, finalValue, "kWh", null));

                lastValidTs = ts;
                if (isEnergyAccumulator) lastValidEnergyValue = value;
            }
            if (skippedGarbage > 0 || skippedWindow > 0 || skippedOutOfOrder > 0 || skippedRetreating > 0) {
                log.debug("sensor={} descartadas: {} lixo(wrap), {} fora-da-janela,"
                        + " {} out-of-order(r7), {} kwh-retrocedendo(r7)",
                    meter.senId(), skippedGarbage, skippedWindow, skippedOutOfOrder, skippedRetreating);
            }
            return readings;
        }
    }

    /**
     * (r6, 13/05/2026) Aplica a MESMA regra de conversao de escala que o
     * {@code deconsysmodbus.service.energyDevice.EnergyDeviceFileProcessor#processRecords} aplica
     * antes de gravar em {@code mqtt.sensordatarecord} (commit 1c28e4d do deconsysmodbus, develop).
     *
     * <p>Sem essa conversao o gap-filler grava valores RAW do gateway (escala 1e13..1e14 pra KWH/
     * KVARH) e quebra a continuidade da curva — o resto do banco vive em escala convertida
     * (~1e8 pro KWH do sensor 30) porque ALL ingestion non-gap-filler passa pelo deconsysmodbus.
     * Reproduzido em prod em 13/05/2026 no run {@code 3091048a...}, KWH @ 07:30 substituido por
     * 1.577e14 em vez de 1.577e8.
     *
     * <p>Regra (so quando deviceType contem "gipam" ou "gimac", inclusive case-insensitive):
     * <ul>
     *   <li>KW_SYS, KW_DMD, KWH, KVA_SYS, KVA_DMD_MAX, KVAH, KVAR_SYS, KVAR_DMD, KVARH
     *       &rarr; <b>divide por 1.000.000</b> (padrao gipam/gimac)
     *   <li><b>Excecao</b>: device MAC = {@code 00:80:67:86:D2:90} + modbus slave = 1
     *       ("GIPAM FABRICA 2 MAIN") &rarr; <b>divide por 1.000</b>
     *   <li>PF_L1, PF_L2, PF_L3, PF_SYS &rarr; divide por 100 se {@code |value| > 9},
     *       senao mantem (raw 9120 vira 0.912; raw 0.912 fica 0.912)
     *   <li>V_*, A_*, HZ &rarr; <b>sem conversao</b>
     * </ul>
     */
    /**
     * (r7, 14/05/2026) Overload com {@code sensorId} — consulta o override
     * {@link #SENSOR_KWH_DIVISOR} primeiro (prevalece sobre {@code deviceTypeName}
     * pra cobrir leituras onde a metadata L1/L2 do CSV não chegou). Fora dos
     * sensores mapeados, cai na regra r6 original.
     */
    static double applyDeviceScale(double raw, String valueType, String deviceTypeName,
                                   String gatewayMac, Integer modbusSlaveId, Long sensorId) {
        if (sensorId != null && SENSOR_KWH_DIVISOR.containsKey(sensorId) && valueType != null) {
            double divisor = SENSOR_KWH_DIVISOR.get(sensorId);
            switch (valueType) {
                case "KW_SYS", "KW_DMD", "KWH",
                     "KVA_SYS", "KVA_DMD_MAX", "KVAH",
                     "KVAR_SYS", "KVAR_DMD", "KVARH" -> {
                    return raw / divisor;
                }
                case "PF_L1", "PF_L2", "PF_L3", "PF_SYS" -> {
                    return Math.abs(raw) > 9 ? raw / 100.0 : raw;
                }
                default -> {
                    // V_*, A_*, HZ: o gateway entrega em unidade correta — sem conversao
                    return raw;
                }
            }
        }
        return applyDeviceScale(raw, valueType, deviceTypeName, gatewayMac, modbusSlaveId);
    }

    static double applyDeviceScale(double raw, String valueType, String deviceTypeName,
                                   String gatewayMac, Integer modbusSlaveId) {
        if (deviceTypeName == null) return raw;
        String dt = deviceTypeName.toLowerCase(Locale.ROOT);
        if (!dt.contains("gipam") && !dt.contains("gimac")) return raw;
        if (valueType == null) return raw;

        switch (valueType) {
            case "KW_SYS", "KW_DMD", "KWH",
                 "KVA_SYS", "KVA_DMD_MAX", "KVAH",
                 "KVAR_SYS", "KVAR_DMD", "KVARH" -> {
                // Excecao GIPAM FABRICA 2 MAIN: MAC + slave=1 -> divisor /1000
                if (gatewayMac != null
                    && "00:80:67:86:D2:90".equalsIgnoreCase(gatewayMac.trim())
                    && modbusSlaveId != null && modbusSlaveId == 1) {
                    return raw / 1_000.0;
                }
                return raw / 1_000_000.0;
            }
            case "PF_L1", "PF_L2", "PF_L3", "PF_SYS" -> {
                return Math.abs(raw) > 9 ? raw / 100.0 : raw;
            }
            default -> {
                // V_*, A_*, HZ etc nao sofrem conversao
                return raw;
            }
        }
    }

    /** Linha plausivel: timestamp num horizonte sensato e valor finito, nao-negativo e nao-absurdo. */
    static boolean isPlausible(LocalDateTime ts, double value) {
        int year = ts.getYear();
        int now = LocalDateTime.now().getYear();
        if (year < 2020 || year > now + 1) return false;
        if (!Double.isFinite(value) || value < 0 || value > MAX_PLAUSIBLE_VALUE) return false;
        return true;
    }

    /**
     * Parseia um numero do CSV tolerando: "16878047232000" e "7969.058" (plain / US-decimal,
     * via Double.parseDouble) e "7.728.264.704.000,00" (grouping BR, via DecimalFormat).
     */
    static double parseNumber(String s) {
        s = s.trim();
        try {
            return Double.parseDouble(s);
        } catch (NumberFormatException ignored) {
            try {
                return BR_FORMAT.parse(s).doubleValue();
            } catch (java.text.ParseException pe) {
                throw new NumberFormatException("nao parseou '" + s + "'");
            }
        }
    }

    /** Mantido por compat com testes anteriores. */
    static double parseBrDecimal(String s) throws java.text.ParseException {
        return BR_FORMAT.parse(s).doubleValue();
    }

    /**
     * Mapeia o nome da coluna do EGX300 -> valuetype. Cobre as 18 colunas do export
     * real (Voltage A-N..C-A, Current A..C, Frequency, Real/Reactive Power Total,
     * Power Factor Sign, Real/Reactive Energy). As strings de valuetype precisam
     * baterem com `mqtt.sensordatarecord.sdr_valuetype` no DB - confirmar antes de
     * ligar a extracao multi-coluna (hoje so "Real Energy (kWh)" -> KWH e usado).
     */
    static String inferValueType(String headerCell) {
        if (headerCell == null) return "UNKNOWN";
        String h = headerCell.toLowerCase(Locale.ROOT);
        // energia (acumuladores)
        if (h.contains("real energy") || h.contains("(kwh)"))     return "KWH";
        if (h.contains("reactive energy") || h.contains("kvarh")) return "KVARH";
        if (h.contains("apparent energy") || h.contains("kvah"))  return "KVAH";
        // tensao
        if (h.contains("voltage")) {
            if (h.contains("a-b")) return "V_L1_L2";
            if (h.contains("b-c")) return "V_L2_L3";
            if (h.contains("c-a")) return "V_L3_L1";
            if (h.contains("a-n")) return "V_L1_N";
            if (h.contains("b-n")) return "V_L2_N";
            if (h.contains("c-n")) return "V_L3_N";
            if (h.contains("l-l"))  return "V_L_L_SYS";
            return "V_L_N_SYS";
        }
        // corrente
        if (h.contains("current")) {
            if (h.matches(".*\\bc\\b.*")) return "A_L3";
            if (h.matches(".*\\bb\\b.*")) return "A_L2";
            if (h.matches(".*\\ba\\b.*")) return "A_L1";
            if (h.contains("avg") || h.contains("average")) return "A_AVG";
            return "A_SYS";
        }
        if (h.contains("frequency"))     return "HZ";
        if (h.contains("power factor"))  return "PF_SYS";
        if (h.contains("real power"))    return "KW_SYS";
        if (h.contains("reactive power")) return "KVAR_SYS";
        if (h.contains("apparent power")) return "KVA_SYS";
        return "UNKNOWN";
    }

    private static String trimAt(String[] row, int idx) {
        if (idx < 0 || idx >= row.length || row[idx] == null) return "";
        return row[idx].trim();
    }
}
