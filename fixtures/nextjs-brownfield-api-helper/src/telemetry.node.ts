import { NodeSDK } from "@opentelemetry/sdk-node";

export function startOtelSdk() {
  const sdk = new NodeSDK({ serviceName: "portal-api" });
  sdk.start();
  return sdk;
}
