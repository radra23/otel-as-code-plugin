export interface Line {
  sku: string;
  qty: number;
  priceCents: number;
}

export interface Order {
  cartId: string;
  lines: Line[];
  status: 'confirmed';
}
