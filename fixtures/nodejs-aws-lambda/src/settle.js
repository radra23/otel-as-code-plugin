// A scheduled (non-HTTP) invocation: no request to wrap, and nothing emits without a wrapper.
exports.handler = async () => {
  return { settled: 0 };
};
