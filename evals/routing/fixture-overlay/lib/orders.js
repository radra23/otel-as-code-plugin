// Order total in cents after a percentage discount, rounded to the nearest cent.
function orderTotal(lines, percentOff = 0) {
  const subtotal = lines.reduce((acc, l) => acc + l.priceCents * l.qty, 0);
  return Math.floor(subtotal * (1 - percentOff / 100));
}

module.exports = { orderTotal };
