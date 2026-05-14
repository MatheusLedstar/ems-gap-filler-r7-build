package br.com.ledstar.ems.gapfiller.infra.http;

import br.com.ledstar.ems.gapfiller.application.MeterDataSource;
import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.cert.X509Certificate;
import java.time.LocalDateTime;
import java.util.Base64;
import java.util.List;

/**
 * Fonte HTTPS para Carlo Gavazzi 69kV (10.193.217.50).
 * Equipamento expoe APENAS porta 443. Firmware antigo usa TLS 1.0/1.2.
 * O .NET FtpWebRequest do PowerShell falhou com "A conexao subjacente estava fechada" -
 * em Java forcamos:
 *   - SSLContext customizado aceitando TLSv1, TLSv1.1, TLSv1.2, TLSv1.3
 *   - TrustAll (equipamento usa cert auto-assinado)
 *   - Basic Auth no header
 *
 * Endpoints provaveis (ainda nao confirmados - precisa do recon HTTPS funcionando):
 *   /em24/values.json, /api/data, /log.csv, /datalogger
 */
@Component
public class HttpsCarloGavazziDataSource implements MeterDataSource {

    private static final Logger log = LoggerFactory.getLogger(HttpsCarloGavazziDataSource.class);

    private final int timeoutMs;

    public HttpsCarloGavazziDataSource(@Value("${gapfiller.carlo-gavazzi.timeout-seconds:15}") int timeoutSec) {
        this.timeoutMs = timeoutSec * 1000;
    }

    @Override
    public boolean supports(SensorMeter meter) {
        return meter.protocol() == SensorMeter.Protocol.HTTPS;
    }

    @Override
    public List<SensorReading> fetchReadings(SensorMeter meter,
                                             LocalDateTime windowStart,
                                             LocalDateTime windowEnd) {
        // Endpoint candidato vem do csvPath - configurado por sensor em ems.ftp_source
        String url = "https://" + meter.meterIp() + meter.csvPath();
        try {
            byte[] body = httpsGet(url, meter.username(), meter.password());
            if (body == null || body.length == 0) {
                log.warn("Carlo Gavazzi {} retornou vazio em {}", meter.meterIp(), url);
                return List.of();
            }
            log.info("Carlo Gavazzi {} GET {} -> {} bytes", meter.meterIp(), url, body.length);
            // TODO: parser do payload (CSV ou JSON dependendo do endpoint)
            return List.of();
        } catch (Exception ex) {
            log.error("Carlo Gavazzi {} fetch falhou: {}", meter.meterIp(), ex.getMessage());
            return List.of();
        }
    }

    private byte[] httpsGet(String url, String user, String pass) throws Exception {
        HttpsURLConnection conn = (HttpsURLConnection) URI.create(url).toURL().openConnection();
        conn.setSSLSocketFactory(trustAllSocketFactory());
        conn.setHostnameVerifier(trustAllHostnames());
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(timeoutMs);
        conn.setReadTimeout(timeoutMs);

        if (user != null && !user.isBlank()) {
            String token = Base64.getEncoder().encodeToString(
                (user + ":" + pass).getBytes(StandardCharsets.UTF_8));
            conn.setRequestProperty("Authorization", "Basic " + token);
        }

        int code = conn.getResponseCode();
        if (code < 200 || code >= 300) {
            log.warn("Carlo Gavazzi {} HTTP {} - {}", url, code, conn.getResponseMessage());
            return null;
        }

        try (InputStream in = conn.getInputStream()) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    private static SSLSocketFactory trustAllSocketFactory() throws Exception {
        TrustManager[] trustAll = new TrustManager[]{
            new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] c, String s) {}
                public void checkServerTrusted(X509Certificate[] c, String s) {}
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }
        };
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, trustAll, new java.security.SecureRandom());
        return ctx.getSocketFactory();
    }

    private static HostnameVerifier trustAllHostnames() {
        return (hostname, session) -> true;
    }
}
