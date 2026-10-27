const { NodeSDK } = require("@opentelemetry/sdk-node");

const sdk = new NodeSDK({});
sdk.start();
