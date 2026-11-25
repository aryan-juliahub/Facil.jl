// Broadcast publisher shared by the WebSocket opponents: n messages at `rate`/s through send(msg).
// Each message carries its sequence number and scheduled send time, so a lagging publisher shows as latency.
function publisher(n, rate, size, send, state) {
  const pad = 'x'.repeat(size - 32);
  const t0 = process.hrtime.bigint();
  let sent = 0;
  const iv = setInterval(() => {
    const due = Math.min(n, Number((process.hrtime.bigint() - t0) * BigInt(rate) / 1000000000n) + 1);
    while (sent < due) {
      send(String(sent).padStart(10, '0') + ' ' + String(t0 + BigInt(sent) * 1000000000n / BigInt(rate)).padStart(20, '0') + ' ' + pad);
      sent++;
    }
    state.published = sent;
    if (sent >= n) clearInterval(iv);
  }, 1);
}
module.exports = { publisher };
