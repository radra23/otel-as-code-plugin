import { logException } from "../../lib/log-exception";

export async function POST(req: Request) {
  const { message } = await req.json();
  logException(new Error(message));
  return new Response(null, { status: 204 });
}
