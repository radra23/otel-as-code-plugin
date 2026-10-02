<?php

namespace App\Http\Controllers;

class InvoiceController
{
    public function show(int $id): array
    {
        return ['id' => $id, 'status' => 'open'];
    }
}
