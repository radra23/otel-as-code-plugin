const fastify = require("fastify")();

fastify.get("/orders/:id", async (request) => ({ id: request.params.id }));

fastify.listen({ port: 3000 });
