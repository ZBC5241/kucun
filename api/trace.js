// Vercel 函数：串码追踪代理
// 用法：GET /trace?csn=串码
const { queryTrace } = require('../kucun-proxy.js');

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (req.method === 'OPTIONS') { res.status(204).end(); return; }
  const u = new URL(req.url, 'http://x');
  const csn = u.searchParams.get('csn') || '';
  try {
    res.status(200).json(await queryTrace(csn));
  } catch (e) {
    res.status(502).json({ error: String((e && e.message) || e) });
  }
};
