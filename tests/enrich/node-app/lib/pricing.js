class Pricing {
  constructor(percentOff) {
    this.percentOff = percentOff;
  }

  total(lines) {
    const subtotal = lines.reduce((acc, l) => acc + l.priceCents * l.qty, 0);
    return Math.round(subtotal * (1 - this.percentOff / 100));
  }

  static describe() {
    return 'percent-off pricing';
  }
}

function total(lines) {
  return lines.length;
}

module.exports = { Pricing, total };
