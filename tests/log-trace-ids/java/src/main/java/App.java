// tests/e2e/log-trace-ids.sh (#279): logs one line per logging library while POST /pay is
// handled. The logging setup is the app's own (logback.xml / log4j2.xml, picked with
// -Dlogback.configurationFile and -Dlog4j2.configurationFile); the agent is the only telemetry.
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;

public class App {
  private static final java.util.logging.Logger JUL = java.util.logging.Logger.getLogger("payments");
  private static final org.slf4j.Logger LOGBACK = org.slf4j.LoggerFactory.getLogger("payments");
  private static final org.apache.logging.log4j.Logger LOG4J2 =
      org.apache.logging.log4j.LogManager.getLogger("payments");

  public static void main(String[] args) throws IOException {
    int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8940"));
    HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
    server.createContext("/health", ex -> respond(ex, "{\"status\":\"ok\"}"));
    server.createContext("/pay", ex -> {
      JUL.info("jul pay line orderId=o1");
      LOGBACK.info("logback pay line orderId=o1");
      LOG4J2.info("log4j2 pay line orderId=o1");
      respond(ex, "{\"paid\":true}");
    });
    server.start();
  }

  static void respond(HttpExchange ex, String body) throws IOException {
    byte[] b = body.getBytes();
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(200, b.length);
    try (OutputStream os = ex.getResponseBody()) {
      os.write(b);
    }
  }
}
