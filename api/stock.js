// Vercel 函数：库存查询代理
// 用法：GET /stock?keyword=产品名&category=可选
// 持 token 逻辑复用 kucun-proxy.js（上游地址/账号/密码走环境变量）
const { queryStock } = require('../kucun-proxy.js');

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
  if (req.method === 'OPTIONS') { res.status(204).end(); return; }
  const u = new URL(req.url, 'http://x');
  const kw = u.searchParams.get('keyword') || '';
  const cat = u.searchParams.get('category') || '';
  try {
    res.status(200).json(await queryStock(kw, cat));
  } catch (e) {
    res.status(502).json({ error: String((e && e.message) || e) });
  }
};
