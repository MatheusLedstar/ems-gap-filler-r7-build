package br.com.ledstar.ems.gapfiller.domain;

import java.util.List;
import java.util.Map;

/**
 * Formulas de derivacao de sensores agregados (planilha Mapeamento EMS).
 *
 * Cada formula combina leituras de sensores fisicos em um sensor logico (F1-F6).
 * O Compressor (sensor 10111) eh distribuido entre 4 fabricas (/4 cada).
 *
 * Exemplo de aplicacao:
 *   F3 = (BM_MV-F3-L1 + UT_MV_F3_L1 + UT_MV_F3_L2 + UT_MV_F3_L3) / 4
 *
 * Estas formulas NAO sao executadas pelo gap-filler na fase MVP - sao apenas
 * documentadas pra referencia futura caso seja necessario re-calcular agregados
 * derivados apos correcao por soft-delete.
 */
public final class DerivedSensorFormula {

    private DerivedSensorFormula() {}

    public record Term(long sensorId, double coefficient, String description) {}

    public record Formula(String name, List<Term> terms, String description) {}

    private static final long BM_MV_F3_L1 = 10109L;
    private static final long BM_MV_F3_L4 = 10154L;
    private static final long UT_MV_F3_L1 = 10112L;
    private static final long UT_MV_F3_L2 = 10110L;
    private static final long UT_MV_F3_L3 = 10111L;   // Compressor
    private static final long UT_MV_F3_L4 = 10105L;
    private static final long F1_BASE     = 12L;
    private static final long F2_BASE     = 13L;

    public static final Map<String, Formula> ALL = Map.of(
        "F1", new Formula("F1",
            List.of(
                new Term(F1_BASE,     1.0,  "F1 base (Carlo Gavazzi sensor 12)"),
                new Term(UT_MV_F3_L3, 0.25, "Compressor /4")
            ),
            "F1 = F1 + (UT_MV_F3_L3) / 4"),

        "F2", new Formula("F2",
            List.of(
                new Term(F2_BASE,     1.0,  "F2 base (Carlo Gavazzi sensor 13)"),
                new Term(UT_MV_F3_L3, 0.25, "Compressor /4")
            ),
            "F2 = F2 + (UT_MV_F3_L3) / 4"),

        "F3", new Formula("F3",
            List.of(
                new Term(BM_MV_F3_L1, 0.25, "BM_MV-F3-L1 / 4"),
                new Term(UT_MV_F3_L1, 0.25, "UT_MV_F3_L1 / 4"),
                new Term(UT_MV_F3_L2, 0.25, "UT_MV_F3_L2 / 4"),
                new Term(UT_MV_F3_L3, 0.25, "UT_MV_F3_L3 (Compressor) / 4")
            ),
            "F3 = (BM_MV-F3-L1 + UT_MV_F3_L1 + UT_MV_F3_L2 + UT_MV_F3_L3) / 4"),

        "F5", new Formula("F5",
            List.of(
                new Term(BM_MV_F3_L4, 0.25, "BM_MV-F3-L4 / 4"),
                new Term(UT_MV_F3_L3, 0.25, "UT_MV_F3_L3 (Compressor) / 4")
            ),
            "F5 = (BM_MV-F3-L4 + UT_MV_F3_L3) / 4"),

        "F6", new Formula("F6",
            List.of(new Term(UT_MV_F3_L4, 1.0, "UT_MV_F3_L4")),
            "F6 = UT_MV_F3_L4")
    );
}
