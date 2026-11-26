<?php
// tests/e2e/log-trace-ids.sh (#279): a PHP script behind the golden telemetry.php that logs one
// line through its own Monolog logger inside a server span. The span is started here, standing in
// for the framework package (opentelemetry-auto-laravel needs the PECL extension); it is made the
// current span the same way, so Span::getCurrent() sees it. LOG_MODE picks the app's own handler
// format (Monolog's default line, a format without %extra%, or JSON); the e2e replaces the line
// after "log setup" with the line /otel-instrument prints, read out of the generator.
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/telemetry.php';

use Monolog\Formatter\JsonFormatter;
use Monolog\Formatter\LineFormatter;
use Monolog\Handler\StreamHandler;
use Monolog\Logger;
use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;

$handler = new StreamHandler('php://stdout');
switch (getenv('LOG_MODE')) {
    case 'own': $handler->setFormatter(new LineFormatter("APP %level_name% | %message%\n")); break;
    case 'json': $handler->setFormatter(new JsonFormatter()); break;
}
$logger = new Logger('app', [$handler]);
// log setup
// (the printed line goes here)

$span = Globals::tracerProvider()->getTracer('log-trace-ids')
    ->spanBuilder('POST /pay')->setSpanKind(SpanKind::KIND_SERVER)->startSpan();
$scope = $span->activate();
try {
    $logger->info('php pay line orderId=o1');
} finally {
    $scope->detach();
    $span->end();
}
$logger->info('php line outside a span');
