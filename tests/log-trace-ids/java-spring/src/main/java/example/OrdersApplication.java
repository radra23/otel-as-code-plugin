// tests/e2e/log-trace-ids.sh (#279): logs one line while GET /orders/{id} is handled, through
// SLF4J on Spring Boot's default Logback setup.
package example;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class OrdersApplication {
  private static final Logger LOG = LoggerFactory.getLogger(OrdersApplication.class);

  public static void main(String[] args) {
    SpringApplication.run(OrdersApplication.class, args);
  }

  @GetMapping("/health")
  public String health() {
    return "ok";
  }

  @GetMapping("/orders/{id}")
  public String order(@PathVariable String id) {
    LOG.info("spring order line id={}", id);
    return "order " + id;
  }
}
