# why-checkout: the /otel-why fixture

One checkout path, three planted causes. Each one is switched on by data or config, not by the
code at the call site, so reading the code does not give the answer away (see the trial notes in
`tests/why/README.md`). `tests/e2e/why.sh` runs each profile against the local stack and asserts
`scripts/trace_summary.py` ranks the planted span first.

| Profile | Switch | Planted span |
|---|---|---|
| `clean` | small cart, fast promotions, light signing | nothing stands out |
| `n-plus-one` | `CART_SEED=large`: a 30-line cart, one catalogue lookup per line | `db.getProduct` |
| `slow-call` | `PROMO_DELAY_MS=600` on the promotions stub | the outbound `GET` to promotions |
| `cpu-bound` | `SIGN_WORK=800000` | `orders.signOrder` |
