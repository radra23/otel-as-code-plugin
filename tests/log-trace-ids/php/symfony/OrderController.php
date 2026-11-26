<?php
// tests/e2e/log-trace-ids.sh copies this into a new Symfony app's src/Controller/. One route with a
// path parameter, so the span the Symfony package makes shows what it names the route
// (/orders/{id} is the template; app_order_show is the route's name).
namespace App\Controller;

use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

final class OrderController
{
    #[Route('/orders/{id}', name: 'app_order_show')]
    public function show(string $id): Response
    {
        return new Response("order {$id}");
    }
}
