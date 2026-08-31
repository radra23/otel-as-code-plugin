// payments-api — a minimal greenfield Java service (pristine / uninstrumented).
// Uses the JDK's built-in com.sun.net.httpserver.HttpServer, which the OpenTelemetry
// Java agent auto-instruments (instrumentation/java-http-server) — no framework or build
// tool required. The e2e harness runs this under -javaagent to prove traces flow.
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;

public class App {
  public static void main(String[] args) throws IOException {
    int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
    HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
    server.createContext("/health", ex -> respond(ex, 200, "{\"status\":\"ok\"}"));
    server.createContext("/pay", ex -> respond(ex, 200, "{\"paid\":true,\"orderId\":\"o1\"}"));
    server.setExecutor(null);
    server.start();
    System.out.println("payments-api listening on port " + port);
  }

  static void respond(HttpExchange ex, int code, String body) throws IOException {
    byte[] b = body.getBytes();
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(code, b.length);
    try (OutputStream os = ex.getResponseBody()) {
      os.write(b);
    }
  }
}
