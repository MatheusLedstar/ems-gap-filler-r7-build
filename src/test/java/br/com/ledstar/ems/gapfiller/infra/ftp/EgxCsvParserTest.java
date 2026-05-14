package br.com.ledstar.ems.gapfiller.infra.ftp;

import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.text.ParseException;
import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class EgxCsvParserTest {

    private final EgxCsvParser parser = new EgxCsvParser();

    /**
     * Cenario do print do Cesar (07/05/2026 sensor BM).
     * A linha 03:37 vem fora de ordem entre 05:20 e 05:30 — caso real reportado
     * pelo Cesar 14/05 (10:40 -> 04:57 -> 10:50 com KWH retrocedendo).
     * Antes do r7 todas as 6 linhas passavam; agora a 03:37 é descartada.
     */
    @Test
    void deveParsearCsvBrEDetectarValores() {
        String csv = """
            Gateway Name,Gateway Serial,Gateway IP Address
            BM,53107597,10.193.217.11

            ,Topic ID14
            ,1.621,00

            Error,UTC Offset,Local Time Stamp,Real Energy (kWh)
            0,-240,07/05/2026 04:30,7.728.264.704.000,00
            0,-240,07/05/2026 04:35,7.728.324.096.000,00
            0,-240,07/05/2026 05:00,7.728.622.080.000,00
            0,-240,07/05/2026 05:20,7.728.861.696.000,00
            0,-240,07/05/2026 03:37,7.728.000.000.000,00
            0,-240,07/05/2026 05:30,7.728.983.552.000,00
            """;

        SensorMeter meter = new SensorMeter(
            1L, 30L, "10.193.217.11",
            SensorMeter.Protocol.FTP, "Administrator", "Gateway",
            1, "/logging/data/MV-F3-M_1.csv",
            Duration.ofMinutes(5), true);

        List<SensorReading> readings = parser.parse(meter,
            csv.getBytes(StandardCharsets.UTF_8),
            null, null);

        // (r7) A linha 23:37 vem fora de ordem entre 05:20 e 05:30 (Bug 1 reportado pelo Cesar):
        // o filtro de monotonia agora a descarta. Antes do r7 todas as 6 linhas passavam.
        assertThat(readings).hasSize(5);
        assertThat(readings.get(0).valueType()).isEqualTo("KWH");
        assertThat(readings.get(0).creation())
            .isEqualTo(LocalDateTime.of(2026, 5, 7, 4, 30));
        assertThat(readings)
            .extracting(SensorReading::creation)
            .doesNotContain(LocalDateTime.of(2026, 5, 7, 3, 37));
    }

    @Test
    void deveFiltrarPorJanela() {
        String csv = """
            Gateway Name,Gateway Serial,Gateway IP Address
            BM,53107597,10.193.217.11

            Error,UTC Offset,Local Time Stamp,Real Energy (kWh)
            0,-240,07/05/2026 04:30,7.728.264.704.000,00
            0,-240,07/05/2026 05:00,7.728.622.080.000,00
            0,-240,07/05/2026 06:00,7.729.000.000.000,00
            """;

        SensorMeter meter = new SensorMeter(
            1L, 30L, "10.193.217.11",
            SensorMeter.Protocol.FTP, "x", "x", 1,
            "/x", Duration.ofMinutes(5), true);

        List<SensorReading> readings = parser.parse(meter,
            csv.getBytes(StandardCharsets.UTF_8),
            LocalDateTime.of(2026, 5, 7, 4, 45),
            LocalDateTime.of(2026, 5, 7, 5, 30));

        assertThat(readings).hasSize(1);
        assertThat(readings.get(0).creation())
            .isEqualTo(LocalDateTime.of(2026, 5, 7, 5, 0));
    }

    @Test
    void deveParsearDecimaisFormatoBR() throws ParseException {
        assertThat(EgxCsvParser.parseBrDecimal("7.728.264.704.000,00"))
            .isCloseTo(7_728_264_704_000.0, org.assertj.core.data.Offset.offset(0.01));
        assertThat(EgxCsvParser.parseBrDecimal("0,12"))
            .isCloseTo(0.12, org.assertj.core.data.Offset.offset(0.001));
    }

    @Test
    void deveInferirValueTypeDoHeader() {
        assertThat(EgxCsvParser.inferValueType("Real Energy (kWh)")).isEqualTo("KWH");
        assertThat(EgxCsvParser.inferValueType("kVArh")).isEqualTo("KVARH");
        assertThat(EgxCsvParser.inferValueType("Frequency")).isEqualTo("HZ");
        assertThat(EgxCsvParser.inferValueType("Power Factor")).isEqualTo("PF_SYS");
    }

    // ----- cenarios com a estrutura REAL do gateway BM (exports MV-F3-1 / MV-F3-4, 11/05/2026) -----

    private static final String REAL_HEADER =
        "Error,UTC Offset (minutes),Local Time Stamp,Voltage A-N,Voltage B-N,Voltage C-N," +
        "Voltage A-B,Voltage B-C,Voltage C-A,Current A,Current B,Current C,Frequency," +
        "Real Power Total (kW),Reactive Power Total (kVAR),Power Factor Sign," +
        "Real Energy (kWh),Reactive Energy (kVARh)";

    private static SensorMeter bmMeter() {
        return new SensorMeter(3L, 10109L, "10.193.217.11", SensorMeter.Protocol.FTP,
            "Administrator", "Gateway", 2, "/logging/data/MV-F3-1_2.csv", Duration.ofMinutes(5), true);
    }

    @Test
    void deveParsearEstruturaRealDe18ColunasEDescartarLixoDoBufferCircular() {
        String csv = "Gateway Name,Gateway SN,Gateway IP Address,Gateway MAC Address,Device Name,Device Local ID,Device Type ID,Device Type Name,Logging Interval,Historical Intervals\n"
            + "BM,53107597,10.193.217.11,00:80:67:86:3A:73,MV-F3-1,2,10002,GIPAM FI,0,0\n"
            + "\n"
            + ",,,Topic ID1,Topic ID2,Topic ID3,Topic ID4,Topic ID5,Topic ID6,Topic ID7,Topic ID8,Topic ID9,Topic ID10,Topic ID11,Topic ID12,Topic ID13,Topic ID14,Topic ID15\n"
            + ",,,1018,1019,1020,1014,1015,1016,1003,1004,1005,-1,1042,1046,-1,1621,1625\n"
            + "\n"
            + REAL_HEADER + "\n"
            + "0,-240,18/03/2026 19:00:00,7969.058,7974.128,7937.908,13833.171,13758.562,13703.51,5.173,5.108,4.682,60.007,108437812.5,40929675.781,-93.557,16878047232000,4109592320000\n"
            + "0,-240,18/03/2026 19:05:00,7954.372,7957.902,7922.21,13798.402,13686.126,13733.934,5.024,5.052,4.625,59.978,105902031.25,41780964.843,-93.022,16878055424000,4109595904000\n"
            // linha-lixo do wrap do buffer: timestamp absurdo + valores absurdos -> deve ser DESCARTADA
            + "16684,-240,23/10/1998 21:24:34,3.90660553895964e+135,0,0,0,0,0,0,0,0,0,0,0,0,5.92313752404218e+28,0\n"
            // linha-lixo parcial: timestamp ok mas Real Energy absurdo (~2.8e17) -> DESCARTADA pelo limite de plausibilidade
            + "0,-240,19/03/2026 23:20:00,7986.571,0,0,0,0,0,0,0,0,60,0,0,0,2.81491858448384e+17,0\n"
            // Error=1 (erro de comunicacao recuperavel) com dados bons -> MANTIDA
            + "1,-240,20/03/2026 02:35:00,8099.876,0,0,0,0,0,0,0,0,60,0,0,0,16881907712000,0\n";

        List<SensorReading> readings = parser.parse(bmMeter(),
            csv.getBytes(StandardCharsets.UTF_8), null, null);

        assertThat(readings).hasSize(3);   // 2 boas + 1 com Error=1 (mantida); as 2 linhas-lixo descartadas
        assertThat(readings).allSatisfy(r -> {
            assertThat(r.valueType()).isEqualTo("KWH");
            assertThat(r.sensorId()).isEqualTo(10109L);
        });
        // (r7) Sensor 10109 está no SENSOR_KWH_DIVISOR com divisor /1.000 (calibrado em prod 14/05).
        // Raw CSV "16878047232000" -> 16878047232.0 (escala observada no banco, ~1.7e10).
        // Antes do r7 (r6) o divisor padrão GIPAM era /1.000.000 e o valor saía como 16878047.232.
        assertThat(readings).extracting(SensorReading::value)
            .containsExactly(16878047232.0, 16878055424.0, 16881907712.0);
        assertThat(readings).extracting(SensorReading::creation)
            .containsExactly(
                LocalDateTime.of(2026, 3, 18, 19, 0, 0),
                LocalDateTime.of(2026, 3, 18, 19, 5, 0),
                LocalDateTime.of(2026, 3, 20, 2, 35, 0));
    }

    @Test
    void deveAceitarTimestampComOuSemSegundos() {
        String csv = REAL_HEADER + "\n"
            + "0,-240,18/03/2026 19:00,7969.058,0,0,0,0,0,0,0,0,60,0,0,0,16878047232000,0\n"
            + "0,-240,18/03/2026 19:05:00,7954.372,0,0,0,0,0,0,0,0,60,0,0,0,16878055424000,0\n";
        List<SensorReading> readings = parser.parse(bmMeter(), csv.getBytes(StandardCharsets.UTF_8), null, null);
        assertThat(readings).extracting(SensorReading::creation)
            .containsExactly(LocalDateTime.of(2026, 3, 18, 19, 0), LocalDateTime.of(2026, 3, 18, 19, 5));
    }

    @Test
    void parseNumberToleraPlainUsDecimalEGroupingBR() {
        assertThat(EgxCsvParser.parseNumber("16878047232000")).isEqualTo(16_878_047_232_000.0);
        assertThat(EgxCsvParser.parseNumber("7969.058"))
            .isCloseTo(7969.058, org.assertj.core.data.Offset.offset(1e-6));
        assertThat(EgxCsvParser.parseNumber("7.728.264.704.000,00"))
            .isCloseTo(7_728_264_704_000.0, org.assertj.core.data.Offset.offset(0.01));
    }

    @Test
    void isPlausibleRejeitaLixoEAceitaBom() {
        LocalDateTime bomTs = LocalDateTime.of(2026, 3, 18, 19, 0);
        assertThat(EgxCsvParser.isPlausible(bomTs, 16_878_047_232_000.0)).isTrue();
        assertThat(EgxCsvParser.isPlausible(LocalDateTime.of(1998, 10, 23, 21, 24), 5.0e28)).isFalse();   // year + valor
        assertThat(EgxCsvParser.isPlausible(bomTs, 2.81491858448384e17)).isFalse();                       // valor > 1e15
        assertThat(EgxCsvParser.isPlausible(bomTs, Double.NaN)).isFalse();
        assertThat(EgxCsvParser.isPlausible(bomTs, -1.0)).isFalse();
        assertThat(EgxCsvParser.isPlausible(LocalDateTime.of(2013, 9, 15, 18, 34), 1.0e12)).isFalse();    // year < 2020
    }

    // ----- timestamp em ambos formatos (BR XLSX vs ISO CSV cru do FTP, confirmado 13/05/2026 prod) -----

    @Test
    void parseTimestampAceitaIsoEBr() {
        // ISO yyyy-MM-dd HH:mm:ss - formato real do CSV cru no FTP do gateway
        assertThat(EgxCsvParser.parseTimestamp("2026-04-27 14:10:00"))
            .isEqualTo(LocalDateTime.of(2026, 4, 27, 14, 10, 0));
        assertThat(EgxCsvParser.parseTimestamp("2026-04-27 14:10"))
            .isEqualTo(LocalDateTime.of(2026, 4, 27, 14, 10));
        // BR dd/MM/yyyy HH:mm[:ss] - formato dos exports XLSX abertos no Excel
        assertThat(EgxCsvParser.parseTimestamp("27/04/2026 14:10:00"))
            .isEqualTo(LocalDateTime.of(2026, 4, 27, 14, 10, 0));
        assertThat(EgxCsvParser.parseTimestamp("27/04/2026 14:10"))
            .isEqualTo(LocalDateTime.of(2026, 4, 27, 14, 10));
    }

    // ----- conversao de escala (r6): mesma regra do deconsysmodbus.EnergyDeviceFileProcessor -----

    @Test
    void applyDeviceScale_gipamEnergiaPotenciaDividePorUmMilhao() {
        // padrao GIPAM: KWH, KVARH, KW_SYS, KVAR_SYS, KVA_SYS, KVAH, KW_DMD, KVA_DMD_MAX, KVAR_DMD -> /1M
        for (String vt : new String[]{"KWH","KVARH","KW_SYS","KVAR_SYS","KVA_SYS","KVAH",
                                      "KW_DMD","KVA_DMD_MAX","KVAR_DMD"}) {
            double out = EgxCsvParser.applyDeviceScale(16878047232000.0, vt, "GIPAM FI",
                                                       "00:80:67:86:3A:73", 2);
            assertThat(out)
                .as("valuetype %s deveria ser dividido por 1M", vt)
                .isEqualTo(16878047.232);
        }
    }

    @Test
    void applyDeviceScale_gipamFabrica2MainDividePorMil() {
        // excecao: MAC 00:80:67:86:D2:90 + slave=1 -> /1000 ao inves de /1M
        double out = EgxCsvParser.applyDeviceScale(16878047232000.0, "KWH",
                                                   "GIPAM FABRICA 2 MAIN",
                                                   "00:80:67:86:D2:90", 1);
        assertThat(out).isEqualTo(16878047232.0);
    }

    @Test
    void applyDeviceScale_gipamFabrica2OutroSlaveAindaUsaUmMilhao() {
        // mesmo MAC mas slave != 1 -> regra padrao /1M
        double out = EgxCsvParser.applyDeviceScale(16878047232000.0, "KWH",
                                                   "GIPAM",
                                                   "00:80:67:86:D2:90", 2);
        assertThat(out).isEqualTo(16878047.232);
    }

    @Test
    void applyDeviceScale_pfDivideCem_seValorMaiorQueNove() {
        // raw 9120 -> 91.2? Nao: 91.20 / 100 = 0.912. Mas no codigo do deconsysmodbus o cmp eh > 9.
        // Entao: raw 9.12 -> mantido como 9.12 (nao divide); raw 9120 -> 91.2.
        assertThat(EgxCsvParser.applyDeviceScale(9120.0, "PF_SYS", "GIPAM FI", "X", 1))
            .isEqualTo(91.2);
        assertThat(EgxCsvParser.applyDeviceScale(0.912, "PF_SYS", "GIPAM FI", "X", 1))
            .isEqualTo(0.912);
        // limite > 9 (e nao >=): 9 fica como 9
        assertThat(EgxCsvParser.applyDeviceScale(9.0, "PF_SYS", "GIPAM FI", "X", 1))
            .isEqualTo(9.0);
        // exato 9.0001 ja divide
        assertThat(EgxCsvParser.applyDeviceScale(9.0001, "PF_SYS", "GIPAM FI", "X", 1))
            .isCloseTo(0.090001, org.assertj.core.data.Offset.offset(1e-9));
    }

    @Test
    void applyDeviceScale_vaHzNaoConverte() {
        // tensao, corrente e frequencia nao sofrem conversao (vem em unidade correta do gateway)
        assertThat(EgxCsvParser.applyDeviceScale(8050.123, "V_L1_N", "GIPAM FI", "X", 1))
            .isEqualTo(8050.123);
        assertThat(EgxCsvParser.applyDeviceScale(155.4, "A_L1", "GIPAM FI", "X", 1))
            .isEqualTo(155.4);
        assertThat(EgxCsvParser.applyDeviceScale(60.038, "HZ", "GIPAM FI", "X", 1))
            .isEqualTo(60.038);
    }

    @Test
    void applyDeviceScale_deviceTypeForaGipamGimacEhNoOp() {
        // sem "gipam"/"gimac" no deviceType -> nao mexe (futuro: Carlo Gavazzi, outros)
        assertThat(EgxCsvParser.applyDeviceScale(123456.0, "KWH", "PM5340", "X", 1))
            .isEqualTo(123456.0);
        assertThat(EgxCsvParser.applyDeviceScale(123456.0, "KWH", "", "X", 1))
            .isEqualTo(123456.0);
        assertThat(EgxCsvParser.applyDeviceScale(123456.0, "KWH", null, "X", 1))
            .isEqualTo(123456.0);
    }

    @Test
    void applyDeviceScale_gimacReconheceMesmaRegra() {
        // o codigo do deconsysmodbus aceita "gimac" OU "gipam"
        assertThat(EgxCsvParser.applyDeviceScale(16878047232000.0, "KWH", "GIMAC X-100", "Y", 5))
            .isEqualTo(16878047.232);
    }

    @Test
    void deveAplicarConversaoDeEscalaQuandoCsvTrazDeviceTypeNaLinha2() {
        // CSV completo: L1 com "Device Type Name" + L2 com "GIPAM FI" + header de dados.
        // O parser deve detectar L1/L2 OPORTUNISTICAMENTE e aplicar a regra de escala.
        String csv = "Gateway Name,Gateway SN,Gateway IP Address,Gateway MAC Address,Device Name,"
            + "Device Local ID,Device Type ID,Device Type Name,Logging Interval,Historical Intervals\n"
            + "BM,53107597,10.193.217.11,00:80:67:86:3A:73,MV-F3-M,1,10002,GIPAM FI,0,0\n"
            + "\n"
            + REAL_HEADER + "\n"
            + "0,-240,2026-04-27 14:10:00,7969.058,0,0,0,0,0,0,0,0,60,0,0,0,16878047232000,4109592320000\n"
            + "0,-240,2026-04-27 14:15:00,7954.372,0,0,0,0,0,0,0,0,60,0,0,0,16878055424000,4109595904000\n";

        List<SensorReading> readings = parser.parse(bmMeter(),
            csv.getBytes(StandardCharsets.UTF_8), null, null);

        assertThat(readings).hasSize(2);
        // (r7) Sensor 10109 -> override /1.000. KWH cru 16878047232000 -> 16878047232.0
        // (escala observada em prod). Antes do r7 (r6) era /1.000.000 = 16878047.232.
        assertThat(readings).extracting(SensorReading::value)
            .containsExactly(16878047232.0, 16878055424.0);
        assertThat(readings).allSatisfy(r -> assertThat(r.valueType()).isEqualTo("KWH"));
    }

    @Test
    void deveParsearCsvCruDoFtpComTimestampIso() {
        // Estrutura EXATA capturada pelo CSV-HEAD-SAMPLE em prod (sensor 30, 13/05/2026)
        String csv = REAL_HEADER + "\n"
            + "0,-240,2026-04-27 14:10:00,7969.058,0,0,0,0,0,0,0,0,60,0,0,0,16878047232000,0\n"
            + "0,-240,2026-04-27 14:15:00,7954.372,0,0,0,0,0,0,0,0,60,0,0,0,16878055424000,0\n"
            + "0,-240,2026-04-27 14:20:00,7986.571,0,0,0,0,0,0,0,0,60,0,0,0,16878063616000,0\n";
        List<SensorReading> readings = parser.parse(bmMeter(),
            csv.getBytes(StandardCharsets.UTF_8), null, null);

        assertThat(readings).hasSize(3);
        assertThat(readings).extracting(SensorReading::creation)
            .containsExactly(
                LocalDateTime.of(2026, 4, 27, 14, 10),
                LocalDateTime.of(2026, 4, 27, 14, 15),
                LocalDateTime.of(2026, 4, 27, 14, 20));
        // (r7) Sensor 10109 -> override /1.000 prevalece mesmo sem L1/L2 metadata no CSV.
        // Antes do r7 (r6) sem metadata o applyDeviceScale era no-op e devolvia raw.
        assertThat(readings).extracting(SensorReading::value)
            .containsExactly(16878047232.0, 16878055424.0, 16878063616.0);
    }

    // ===== r7: testes novos (Bug 1 monotonia + Bug 2 override por sensor_id) =====

    @Test
    void applyDeviceScale_sensorIdNoOverridePrevaleceSemDeviceType() {
        // sensor 30: override /1.000 — aplica mesmo sem deviceTypeName ou MAC (caso real:
        // outliers RAW puro que escaparam pq metadata L1/L2 do CSV não chegou)
        double out = EgxCsvParser.applyDeviceScale(157_779_869_696.0, "KWH",
                                                   null, null, null, 30L);
        assertThat(out).isEqualTo(157_779_869.696);
    }

    @Test
    void applyDeviceScale_sensorIdNoOverrideDividePor1MQuandoNaoEhSensor30Nem10109() {
        // sensor 10110, 10111, 10112, 10154, 21, 10105 -> /1.000.000
        for (long sid : new long[]{21L, 10105L, 10110L, 10111L, 10112L, 10154L}) {
            double out = EgxCsvParser.applyDeviceScale(16878047232000.0, "KWH",
                                                       "GIPAM FI", "00:80:67:86:3A:73", 2, sid);
            assertThat(out)
                .as("sensor %d com override /1M", sid)
                .isEqualTo(16878047.232);
        }
    }

    @Test
    void applyDeviceScale_sensorIdForaDoMapaCaiNaRegraR6() {
        // sensor 9999 não está mapeado -> cai na regra r6 (GIPAM padrão /1M)
        double out = EgxCsvParser.applyDeviceScale(16878047232000.0, "KWH",
                                                   "GIPAM FI", "00:80:67:86:3A:73", 2, 9999L);
        assertThat(out).isEqualTo(16878047.232);
    }

    @Test
    void applyDeviceScale_sensorIdComOverrideNaoConvertVoltageCorrenteFreq() {
        // override só atua em KWH/KVARH/etc. V_*, A_*, HZ continuam sem conversão.
        assertThat(EgxCsvParser.applyDeviceScale(7969.058, "V_L1_N", "GIPAM FI", "X", 1, 30L))
            .isEqualTo(7969.058);
        assertThat(EgxCsvParser.applyDeviceScale(155.4, "A_L1", "GIPAM FI", "X", 1, 30L))
            .isEqualTo(155.4);
        assertThat(EgxCsvParser.applyDeviceScale(60.038, "HZ", "GIPAM FI", "X", 1, 30L))
            .isEqualTo(60.038);
    }

    @Test
    void applyDeviceScale_sensorIdComOverrideAindaTrataPowerFactor() {
        // PF cai na mesma regra (divide /100 se > 9, mantém senão)
        assertThat(EgxCsvParser.applyDeviceScale(9120.0, "PF_SYS", null, null, null, 30L))
            .isEqualTo(91.2);
        assertThat(EgxCsvParser.applyDeviceScale(0.912, "PF_SYS", null, null, null, 30L))
            .isEqualTo(0.912);
    }

    @Test
    void parser_descartaLinhaComTimestampRetrocedendo() {
        // Reproduz o caso do Cesar: 04:30 -> 04:35 -> 04:20 (retrocesso) -> 04:40
        String csv = REAL_HEADER + "\n"
            + "0,-240,2026-05-13 04:30:00,7969.058,0,0,0,0,0,0,0,0,60,0,0,0,16878047232000,0\n"
            + "0,-240,2026-05-13 04:35:00,7954.372,0,0,0,0,0,0,0,0,60,0,0,0,16878055424000,0\n"
            + "0,-240,2026-05-13 04:20:00,7960.000,0,0,0,0,0,0,0,0,60,0,0,0,16878000000000,0\n"
            + "0,-240,2026-05-13 04:40:00,7986.571,0,0,0,0,0,0,0,0,60,0,0,0,16878063616000,0\n";

        List<SensorReading> readings = parser.parse(bmMeter(),
            csv.getBytes(StandardCharsets.UTF_8), null, null);

        // A linha 04:20 (entre 04:35 e 04:40) deve ser descartada por monotonia
        assertThat(readings).hasSize(3);
        assertThat(readings).extracting(SensorReading::creation)
            .containsExactly(
                LocalDateTime.of(2026, 5, 13, 4, 30),
                LocalDateTime.of(2026, 5, 13, 4, 35),
                LocalDateTime.of(2026, 5, 13, 4, 40));
    }

    @Test
    void parser_descartaLinhaComKwhRetrocedendoMaisDe1Pct() {
        // Sequência cronológica OK mas KWH retrocede 5% em uma linha -> wrap/RAW out-of-order
        String csv = REAL_HEADER + "\n"
            + "0,-240,2026-05-13 04:30:00,7969.058,0,0,0,0,0,0,0,0,60,0,0,0,16878047232000,0\n"
            + "0,-240,2026-05-13 04:35:00,7954.372,0,0,0,0,0,0,0,0,60,0,0,0,16878055424000,0\n"
            + "0,-240,2026-05-13 04:40:00,7960.000,0,0,0,0,0,0,0,0,60,0,0,0,16000000000000,0\n"
            + "0,-240,2026-05-13 04:45:00,7986.571,0,0,0,0,0,0,0,0,60,0,0,0,16878063616000,0\n";

        List<SensorReading> readings = parser.parse(bmMeter(),
            csv.getBytes(StandardCharsets.UTF_8), null, null);

        // A linha 04:40 (KWH cai ~5% vs 04:35) deve ser descartada por retrocesso de acumulador
        assertThat(readings).hasSize(3);
        assertThat(readings).extracting(SensorReading::creation)
            .doesNotContain(LocalDateTime.of(2026, 5, 13, 4, 40));
    }

    @Test
    void parser_aceitaRetrocessoPequenoComoRuido() {
        // KWH cai 0.5% — abaixo do limite KWH_RETROCESSO_MAX (1%) — mantém
        String csv = REAL_HEADER + "\n"
            + "0,-240,2026-05-13 04:30:00,7969.058,0,0,0,0,0,0,0,0,60,0,0,0,16878047232000,0\n"
            + "0,-240,2026-05-13 04:35:00,7960.000,0,0,0,0,0,0,0,0,60,0,0,0,16793657187840,0\n"; // -0.5%

        List<SensorReading> readings = parser.parse(bmMeter(),
            csv.getBytes(StandardCharsets.UTF_8), null, null);

        assertThat(readings).hasSize(2);
    }
}
