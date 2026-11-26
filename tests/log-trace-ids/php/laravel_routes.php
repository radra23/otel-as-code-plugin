
// tests/e2e/log-trace-ids.sh (#279) appends this to a new Laravel app's routes/web.php. The span
// is started here, standing in for opentelemetry-auto-laravel (which needs the PECL extension),
// and made current the same way, so the processor sees it through Span::getCurrent().
Route::get('/orders/{id}', function (string $id) {
    $span = \OpenTelemetry\API\Globals::tracerProvider()->getTracer('log-trace-ids')
        ->spanBuilder('GET /orders/{id}')
        ->setSpanKind(\OpenTelemetry\API\Trace\SpanKind::KIND_SERVER)
        ->startSpan();
    $scope = $span->activate();
    try {
        \Illuminate\Support\Facades\Log::info("laravel order line id={$id}");
    } finally {
        $scope->detach();
        $span->end();
    }
    return 'ok';
});
Route::get('/health', fn () => 'ok');
