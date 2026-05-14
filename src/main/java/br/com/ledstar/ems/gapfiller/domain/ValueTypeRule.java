package br.com.ledstar.ems.gapfiller.domain;

import java.util.Map;
import java.util.Set;

/**
 * Regras de validacao por valuetype.
 * KWH/KVARH = acumuladores cumulativos (monotonicos crescentes)
 * V_* = tensao, range fisico
 * A_* = corrente, range fisico
 * HZ = frequencia da rede 50-65
 */
public record ValueTypeRule(
    String valueType,
    boolean monotonicIncreasing,    // true para acumuladores (KWH, KVARH)
    Double minValue,
    Double maxValue
) {
    public static final Set<String> CUMULATIVE = Set.of(
        "KWH", "KVARH", "KVAH",
        "KWH_L1", "KWH_L2", "KWH_L3",
        "KVARH_", "KWH_"
    );

    public static final Map<String, double[]> RANGES = Map.ofEntries(
        // tensao em V (linha-linha 13.8kV ou linha-neutro 8kV)
        Map.entry("V_L1_N",     new double[]{0.0, 30_000.0}),
        Map.entry("V_L2_N",     new double[]{0.0, 30_000.0}),
        Map.entry("V_L3_N",     new double[]{0.0, 30_000.0}),
        Map.entry("V_L1_L2",    new double[]{0.0, 30_000.0}),
        Map.entry("V_L2_L3",    new double[]{0.0, 30_000.0}),
        Map.entry("V_L3_L1",    new double[]{0.0, 30_000.0}),
        Map.entry("V_L_L_SYS",  new double[]{0.0, 30_000.0}),
        Map.entry("V_L_N_SYS",  new double[]{0.0, 30_000.0}),

        // corrente em A
        Map.entry("A_L1",       new double[]{-2_000.0, 2_000.0}),
        Map.entry("A_L2",       new double[]{-2_000.0, 2_000.0}),
        Map.entry("A_L3",       new double[]{-2_000.0, 2_000.0}),
        Map.entry("A_SYS",      new double[]{-2_000.0, 2_000.0}),
        Map.entry("A_AVG",      new double[]{-2_000.0, 2_000.0}),

        // frequencia 60Hz +/- ANEEL
        Map.entry("HZ",         new double[]{50.0, 65.0}),

        // potencia ativa por fase (kW) - aceita negativo (geracao)
        Map.entry("KW_L1",      new double[]{-50_000.0, 50_000.0}),
        Map.entry("KW_L2",      new double[]{-50_000.0, 50_000.0}),
        Map.entry("KW_L3",      new double[]{-50_000.0, 50_000.0}),
        Map.entry("KW_SYS",     new double[]{-50_000.0, 50_000.0}),
        Map.entry("KW_DMD",     new double[]{0.0, 50_000.0}),

        // potencia reativa por fase (kVAr)
        Map.entry("KVAR_L1",    new double[]{-50_000.0, 50_000.0}),
        Map.entry("KVAR_L2",    new double[]{-50_000.0, 50_000.0}),
        Map.entry("KVAR_L3",    new double[]{-50_000.0, 50_000.0}),
        Map.entry("KVAR_SYS",   new double[]{-50_000.0, 50_000.0}),

        // potencia aparente
        Map.entry("KVA_L1",     new double[]{0.0, 50_000.0}),
        Map.entry("KVA_L2",     new double[]{0.0, 50_000.0}),
        Map.entry("KVA_L3",     new double[]{0.0, 50_000.0}),
        Map.entry("KVA_SYS",    new double[]{0.0, 50_000.0}),

        // fator de potencia (-1 a 1)
        Map.entry("PF_L1",      new double[]{-1.0, 1.0}),
        Map.entry("PF_L2",      new double[]{-1.0, 1.0}),
        Map.entry("PF_L3",      new double[]{-1.0, 1.0}),
        Map.entry("PF_SYS",     new double[]{-1.0, 1.0})
    );

    public static ValueTypeRule forValueType(String vt) {
        boolean cumulative = CUMULATIVE.contains(vt);
        double[] range = RANGES.getOrDefault(vt, new double[]{Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY});
        return new ValueTypeRule(vt, cumulative, range[0], range[1]);
    }
}
