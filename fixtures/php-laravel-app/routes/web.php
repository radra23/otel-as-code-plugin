<?php

use App\Http\Controllers\InvoiceController;
use Illuminate\Support\Facades\Route;

Route::get('/invoices/{id}', [InvoiceController::class, 'show']);
Route::get('/healthz', fn () => ['ok' => true]);
