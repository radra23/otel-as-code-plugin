// Order handling in TypeScript, in the shapes a NestJS service and a Next.js route handler take.
// The shapes here are the ones /otel-enrich has to recognise.
import type { Line, Order } from './types';

function Injectable(): ClassDecorator {
  return () => undefined;
}

export interface OrdersApi {
  checkout(cartId: string, fail?: boolean): Promise<Order>;
}

export class LinesRepo {
  async load(cartId: string): Promise<Line[]> {
    await Promise.resolve(cartId);
    return [{ sku: 'sku-1', qty: 1, priceCents: 500 }, { sku: 'sku-2', qty: 2, priceCents: 250 }];
  }
}

@Injectable()
export class OrdersService implements OrdersApi {
  constructor(private readonly repo: LinesRepo) {}

  public async checkout(cartId: string, fail = false): Promise<Order> {
    const startedAt: number = Date.now();
    const lines = await loadLines(this.repo, cartId);
    if (fail) {
      throw new Error(`cart ${cartId} could not be charged`);
    }
    return { cartId, lines, status: 'confirmed' };
  }
}

export const loadLines = async (repo: LinesRepo, cartId: string): Promise<Array<{ sku: string; qty: number; priceCents: number }>> => {
  const lines = await repo.load(cartId);
  return lines;
};

export function total<T extends { qty: number; priceCents: number }>(lines: T[]): number {
  return lines.reduce((acc, l) => acc + l.qty * l.priceCents, 0);
}

export function parse(x: string): number;
export function parse(x: number): number;
export function parse(x: string | number): number {
  return typeof x === 'number' ? x : Number(x);
}

type Describe = (order: Order) => string;

export const describe: Describe = (order) => {
  return `${order.cartId}: ${order.lines.map((l) => `${l.sku}x${l.qty}`).join(', ')}`;
};

// A Next.js route handler's shape: the request in, a response out.
export async function POST(request: { json(): Promise<{ cartId?: string; fail?: boolean }> }): Promise<{ status: number; body: string }> {
  const input = await request.json();
  try {
    const order = await new OrdersService(new LinesRepo()).checkout(input.cartId ?? 'cart-1', input.fail === true);
    return { status: 200, body: JSON.stringify({ ...order, totalCents: total(order.lines) }) };
  } catch (err) {
    return { status: 500, body: JSON.stringify({ error: (err as Error).message }) };
  }
}

export const subtotal = (lines: Line[]): number => lines.reduce((acc, l) => acc + l.priceCents, 0);
