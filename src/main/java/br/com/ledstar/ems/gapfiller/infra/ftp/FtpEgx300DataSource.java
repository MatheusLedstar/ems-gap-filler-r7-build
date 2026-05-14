package br.com.ledstar.ems.gapfiller.infra.ftp;

import br.com.ledstar.ems.gapfiller.application.MeterDataSource;
import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.apache.commons.net.ftp.FTPClient;
import org.apache.commons.net.ftp.FTPReply;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;

/**
 * Cliente FTP ATIVO pra Schneider EGX300.
 *
 * Trata o caso 550 que vimos com FtpWebRequest do PowerShell:
 *   - LIST funciona, RETR retorna 550 "arquivo nao disponivel"
 *
 * Estrategias do Apache Commons Net que NAO existem no FtpWebRequest:
 *   1) Sessao keep-alive (LIST + RETR sem reconectar)
 *   2) BINARY mode explicito ANTES de RETR
 *   3) PASSIVE mode controlado
 *   4) CWD primeiro, depois RETR com nome relativo
 *   5) setControlEncoding pra paths com caracteres especiais
 */
@Component
public class FtpEgx300DataSource implements MeterDataSource {

    private static final Logger log = LoggerFactory.getLogger(FtpEgx300DataSource.class);

    private final int connectTimeoutMs;
    private final int dataTimeoutMs;
    private final int retryAttempts;
    private final long retryBackoffMs;
    private final EgxCsvParser parser;

    public FtpEgx300DataSource(@Value("${gapfiller.ftp.timeout-seconds:30}") int timeoutSec,
                               @Value("${gapfiller.ftp.retry-attempts:3}") int retryAttempts,
                               @Value("${gapfiller.ftp.retry-backoff-seconds:5}") int retryBackoffSec,
                               EgxCsvParser parser) {
        this.connectTimeoutMs = timeoutSec * 1000;
        this.dataTimeoutMs = timeoutSec * 1000;
        this.retryAttempts = retryAttempts;
        this.retryBackoffMs = retryBackoffSec * 1000L;
        this.parser = parser;
    }

    @Override
    public boolean supports(SensorMeter meter) {
        return meter.protocol() == SensorMeter.Protocol.FTP
            && meter.csvPath() != null
            && !meter.csvPath().isBlank();
    }

    @Override
    public List<SensorReading> fetchReadings(SensorMeter meter,
                                             LocalDateTime windowStart,
                                             LocalDateTime windowEnd) {
        for (int attempt = 1; attempt <= retryAttempts; attempt++) {
            try {
                byte[] csvBytes = downloadOnce(meter);
                if (csvBytes != null && csvBytes.length > 0) {
                    return parser.parse(meter, csvBytes, windowStart, windowEnd);
                }
            } catch (Exception ex) {
                log.warn("FTP fetch attempt {}/{} falhou para {}: {}",
                    attempt, retryAttempts, meter.meterIp(), ex.getMessage());
                if (attempt < retryAttempts) {
                    try {
                        Thread.sleep(retryBackoffMs * attempt);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        return List.of();
                    }
                }
            }
        }
        return List.of();
    }

    /**
     * Baixa o CSV completo do gateway via FTP em UMA sessao.
     * Sequencia critica pra contornar o erro 550 do EGX300:
     *   connect -> login -> setBufferSize -> setFileType(BINARY) ->
     *   enterLocalPassiveMode -> CWD pra dir do arquivo -> RETR com nome relativo
     */
    private byte[] downloadOnce(SensorMeter meter) throws IOException {
        String path = meter.csvPath();
        String dir, file;
        int slash = path.lastIndexOf('/');
        if (slash > 0) {
            dir  = path.substring(0, slash);
            file = path.substring(slash + 1);
        } else {
            dir  = "/";
            file = path;
        }

        FTPClient ftp = new FTPClient();
        ftp.setConnectTimeout(connectTimeoutMs);
        ftp.setDataTimeout(java.time.Duration.ofMillis(dataTimeoutMs));
        ftp.setControlEncoding("UTF-8");
        ftp.setBufferSize(1024 * 32);

        try {
            log.debug("FTP connect {}:{}", meter.meterIp(), 21);
            ftp.connect(meter.meterIp(), 21);
            int reply = ftp.getReplyCode();
            if (!FTPReply.isPositiveCompletion(reply)) {
                throw new IOException("FTP refused connection: code=" + reply);
            }

            if (!ftp.login(meter.username(), meter.password())) {
                throw new IOException("FTP login failed for " + meter.username());
            }

            ftp.enterLocalPassiveMode();

            if (!ftp.setFileType(FTPClient.BINARY_FILE_TYPE)) {
                log.warn("setFileType(BINARY) returned false but continuing");
            }

            // CWD primeiro - workaround para 550 do EGX300
            if (!"/".equals(dir) && !ftp.changeWorkingDirectory(dir)) {
                throw new IOException("CWD failed for " + dir + ": " + ftp.getReplyString());
            }

            // RETR com nome relativo (apos CWD)
            try (InputStream in = ftp.retrieveFileStream(file)) {
                if (in == null) {
                    throw new IOException("retrieveFileStream returned null: " + ftp.getReplyString());
                }
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                if (!ftp.completePendingCommand()) {
                    log.warn("completePendingCommand false: {}", ftp.getReplyString());
                }
                byte[] bytes = out.toByteArray();
                log.info("FTP RETR OK {}/{} -> {} bytes", dir, file, bytes.length);
                return bytes;
            }

        } finally {
            try {
                if (ftp.isConnected()) {
                    ftp.logout();
                    ftp.disconnect();
                }
            } catch (IOException ignored) {}
        }
    }
}
