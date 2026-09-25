const { DynamoDBClient, PutItemCommand } = require('@aws-sdk/client-dynamodb');

const ddb = new DynamoDBClient({});

// Lambda is invoked by the runtime, not by an inbound HTTP server in this process — so as with
// Azure Functions, instrumentation-http emits no SERVER span and the DynamoDB CLIENT span below
// is orphaned. Same class of gap, different vendor.
exports.handler = async (event) => {
  const body = JSON.parse(event.body || '{}');
  await ddb.send(new PutItemCommand({
    TableName: process.env.PAYMENTS_TABLE,
    Item: { id: { S: String(body.id) } },
  }));
  return { statusCode: 202, body: JSON.stringify({ accepted: true }) };
};
