// Browser side of the helper. Signs everything with the injected wallet (MetaMask / Rabby):
//   1. one ERC-20 approve of IMD to Permit2
//   2. per order: the Permit2 payment (x402 "exact" scheme) and the EIP-712 QuoteApproval
// Follows the IMD docs' flow exactly (quote → 402 challenge → PAYMENT-SIGNATURE + quoteSignature → poll).
import { createWalletClient, createPublicClient, custom, http, formatEther, parseEther, sha256, stringToBytes, maxUint256 } from 'viem';
import { mainnet } from 'viem/chains';
import { x402Client } from '@x402/core/client';
import { encodePaymentSignatureHeader } from '@x402/core/http';
import { ExactEvmScheme } from '@x402/evm/exact/client';

const IMD = '0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7';
const PERMIT2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3';
const ERC20 = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ name: 'o', type: 'address' }, { name: 's', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ name: 's', type: 'address' }, { name: 'v', type: 'uint256' }], outputs: [{ type: 'bool' }] },
];

const $ = (id) => document.getElementById(id);
const pub = createPublicClient({ chain: mainnet, transport: http('https://ethereum-rpc.publicnode.com') });
let wallet = null;
let account = null;
const orders = [];

// canonical JSON: sorted keys, no whitespace, integers only, no undefined (from the docs)
const canon = (v) => v === null ? 'null' : Array.isArray(v) ? `[${v.map(canon).join(',')}]`
  : typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`
  : JSON.stringify(v);

function step(text, cls = '') {
  const d = document.createElement('div');
  d.className = `step ${cls}`;
  d.textContent = text;
  $('steps').appendChild(d);
  return d;
}

async function refresh() {
  if (!account) return;
  const [eth, imd, allow, chainId] = await Promise.all([
    pub.getBalance({ address: account }),
    pub.readContract({ address: IMD, abi: ERC20, functionName: 'balanceOf', args: [account] }),
    pub.readContract({ address: IMD, abi: ERC20, functionName: 'allowance', args: [account, PERMIT2] }),
    wallet.getChainId(),
  ]);
  $('addr').textContent = account;
  $('chain').textContent = chainId === 1 ? 'Ethereum mainnet (1)' : `chain ${chainId} — switch to mainnet`;
  $('chain').className = chainId === 1 ? 'ok' : 'bad';
  $('eth').textContent = `${formatEther(eth)} ETH`;
  $('imd').textContent = `${formatEther(imd)} IMD`;
  $('allow').textContent = allow >= maxUint256 / 2n ? 'unlimited' : `${formatEther(allow)} IMD`;
  $('allow').className = allow >= parseEther('0.5') ? 'ok' : 'bad';
  $('approve').disabled = false;
  $('pay').disabled = !(chainId === 1 && allow >= parseEther('0.5') && imd >= parseEther('0.5'));
}

$('connect').onclick = async () => {
  if (!window.ethereum) return alert('No injected wallet found. Install MetaMask or Rabby.');
  wallet = createWalletClient({ chain: mainnet, transport: custom(window.ethereum) });
  [account] = await wallet.requestAddresses();
  await refresh();
};
$('refresh').onclick = refresh;

$('approve').onclick = async () => {
  const hash = await wallet.writeContract({ account, address: IMD, abi: ERC20, functionName: 'approve', args: [PERMIT2, parseEther('25')] });
  step(`approve sent: ${hash}`);
  await pub.waitForTransactionReceipt({ hash });
  step('approve confirmed', 'done');
  await refresh();
};

async function loadPresets() {
  const jobs = await (await fetch('/jobs')).json();
  const sel = $('preset');
  for (const name of Object.keys(jobs)) {
    const o = document.createElement('option');
    o.value = name; o.textContent = name; sel.appendChild(o);
  }
  const apply = () => {
    const j = jobs[sel.value];
    if (!j) return;
    $('action').value = j.action || 'launch.open';
    const input = { ...j.input };
    $('input').value = JSON.stringify(input, null, 2);
    if (input.chainId) $('chainId').value = String(input.chainId);
  };
  sel.onchange = apply;
  if (sel.options.length) { sel.value = 'launch-hook-v3.json' in jobs ? 'launch-hook-v3.json' : sel.options[0].value; apply(); }
}

function currentInput() {
  const input = JSON.parse($('input').value);
  const chainId = Number($('chainId').value);
  if (chainId) input.chainId = chainId;
  return input;
}

$('check').onclick = async () => {
  $('checkOut').textContent = 'checking…';
  const r = await fetch('/api/check', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action: $('action').value, input: currentInput() }) });
  const j = await r.json();
  const summary = { status: r.status, kind: j.kind, blockers: j.blockers, suggestions: j.suggestions, problems: j.problems, detail: j.detail, plan: (j.plan || []).map((p) => p.title || p) };
  $('checkOut').textContent = JSON.stringify(summary, null, 2);
  $('checkOut').className = (j.blockers && j.blockers.length) || j.problems ? 'bad' : 'ok';
};

$('pay').onclick = async () => {
  $('steps').innerHTML = '';
  $('payOut').textContent = '';
  try {
    const action = $('action').value;
    const input = currentInput();
    // 1. quote (free; holds the price for 600 s)
    const requestKey = crypto.randomUUID();
    const qr = await fetch('/api/quote', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ requestKey, action, input }) });
    const qj = await qr.json();
    if (!qr.ok) throw new Error(`quote ${qr.status}: ${JSON.stringify(qj).slice(0, 600)}`);
    const orderId = qj.order.id;
    const price = qj.order.quote.payment.amount;
    step(`quoted order ${orderId}: ${formatEther(BigInt(price))} IMD, expires ${new Date(qj.order.quote.expiresAt * 1000).toLocaleTimeString()}`, 'done');
    // 2. challenge
    const cr = await fetch(`/api/submit/${orderId}`, { method: 'POST' });
    const ch = await cr.json();
    if (cr.status !== 402) throw new Error(`expected 402 challenge, got ${cr.status}: ${JSON.stringify(ch).slice(0, 600)}`);
    const req = ch.accepts[0];
    step(`challenge: pay ${formatEther(BigInt(req.amount))} IMD to ${req.payTo} on ${req.network}`, 'done');
    // 3. Permit2 payment (signature 1)
    const client = x402Client.fromConfig({ schemes: [{ network: req.network, client: new ExactEvmScheme(wallet) }] });
    const { extensions, ...generated } = await client.createPaymentPayload({ x402Version: 2, resource: ch.resource, accepts: [req] });
    const payment = JSON.parse(JSON.stringify({ ...generated, accepted: req }));
    step('Permit2 payment signed', 'done');
    // 4. QuoteApproval (signature 2)
    const q = ch.quote;
    const quoteSignature = await wallet.signTypedData({
      account,
      domain: { name: 'IdentityMD Paid Action', version: '1', chainId: Number(q.payment.network.slice(7)) },
      primaryType: 'QuoteApproval',
      types: { QuoteApproval: [
        { name: 'resource', type: 'string' },
        { name: 'requesterScopeHash', type: 'bytes32' },
        { name: 'quoteId', type: 'string' },
        { name: 'quoteHash', type: 'bytes32' },
        { name: 'paymentHash', type: 'bytes32' },
        { name: 'action', type: 'string' },
        { name: 'asset', type: 'address' },
        { name: 'amount', type: 'uint256' },
        { name: 'payTo', type: 'address' },
        { name: 'expiresAt', type: 'uint256' },
      ] },
      message: {
        resource: ch.resourceUrl,
        requesterScopeHash: `0x${ch.requesterScopeHash}`,
        quoteId: q.id,
        quoteHash: `0x${q.quoteHash}`,
        paymentHash: sha256(stringToBytes(canon(payment))),
        action: q.action,
        asset: q.payment.asset,
        amount: BigInt(q.payment.amount),
        payTo: q.payment.payTo,
        expiresAt: BigInt(q.expiresAt),
      },
    });
    step('quote approval signed', 'done');
    // 5. submit
    const sr = await fetch(`/api/submit/${orderId}`, { method: 'POST', headers: { 'content-type': 'application/json', 'PAYMENT-SIGNATURE': encodePaymentSignatureHeader(payment) }, body: JSON.stringify({ quoteSignature }) });
    const sj = await sr.json();
    if (!(sr.status === 202 || sr.status === 200)) throw new Error(`submit ${sr.status}: ${JSON.stringify(sj).slice(0, 800)}`);
    step(`submitted (${sr.status})`, 'done');
    orders.push({ orderId, action, at: new Date().toISOString() });
    $('orders').textContent = JSON.stringify(orders, null, 2);
    // 6. poll
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 5000));
      const pr = await fetch(`/api/requests/${orderId}`);
      const pj = await pr.json();
      $('payOut').textContent = JSON.stringify(pj, null, 2);
      if (pj.status === 'admitted') {
        const res = pj.admission?.result || {};
        step(`admitted: ${res.kind} ${res.jobId || res.workflowId || ''} → https://explorer.imd.fun/jobs/${res.jobId || ''}`, 'done');
        return;
      }
      if (pj.status === 'payment_failed' || pj.status === 'expired') throw new Error(`order ${pj.status}: ${JSON.stringify(pj.payment || pj).slice(0, 600)}`);
    }
    step('still pending after 5 minutes; keep this order id and poll /api/requests/<id>', '');
  } catch (e) {
    step(String(e.message || e), 'fail');
    $('payOut').textContent += `\n${String(e.stack || e)}`;
  }
};

loadPresets();
