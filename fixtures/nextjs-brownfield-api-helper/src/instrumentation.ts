export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { startOtelSdk } = await import("./telemetry.node");
    startOtelSdk();
  }
}

export async function onRequestError(err: unknown) {
  const { logException } = await import("./lib/log-exception");
  logException(err);
}
