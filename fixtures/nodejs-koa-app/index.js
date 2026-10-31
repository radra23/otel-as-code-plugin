const Koa = require("koa");

const app = new Koa();

app.use(async (ctx) => {
  ctx.body = { status: "ok" };
});

app.listen(3000);
