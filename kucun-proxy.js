#!/usr/bin/env node
/**
 * kucun 轻量代理
 * - 登录拿 Bearer token（内存缓存 55min，401 自动刷新）
 * - 转发 库存查询 / 串码追踪 到辅助查询系统，补 CORS 头
 * - 前端不直接持有密码，密码走环境变量 KUCUN_PWD（默认 1，生产请改强密码）
 * - 两种运行方式：
 *   1) standalone:  node kucun-proxy.js   -> http://127.0.0.1:8787
 *   2) Vercel 函数: 复制本文件逻辑到 api/stock.js / api/trace.js（见文档）
 */
'use strict';
const http = require('http');
const https = require('https');

const API_BASE = process.env.KUCUN_API_BASE || 'http://116.205.105.166:20265';
const USERNAME = process.env.KUCUN_USER || '20230528';
const PASSWORD = process.env.KUCUN_PWD || '1';
const TOKEN_TTL = 55 * 60 * 1000; // 55 分钟

let tokenCache = { token: null, ts: 0 };

function req(method, path, body, token) {
  return new Promise((resolve, reject) => {
    const url = new URL(API_BASE + path);
    const data = body ? JSON.stringify(body) : null;
    const lib = url.protocol === 'https:' ? https : http;
    const options = {
      method,
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + url.search,
      headers: { 'Content-Type': 'application/json' },
    };
    if (token) options.headers['Authorization'] = 'Bearer ' + token;
    if (data) options.headers['Content-Length'] = Buffer.byteLength(data);
    const r = lib.request(options, (res) => {
      let buf = '';
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        let json;
        try { json = JSON.parse(buf); } catch (e) { json = { _raw: buf }; }
        resolve({ status: res.statusCode, json });
      });
    });
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

async function getToken() {
  const now = Date.now();
  if (tokenCache.token && now - tokenCache.ts < TOKEN_TTL) return tokenCache.token;
  const { json } = await req('POST', '/api/auth/login', { username: USERNAME, password: PASSWORD });
  if (!json || !json.token) throw new Error('login failed: ' + JSON.stringify(json));
  tokenCache = { token: json.token, ts: now };
  return json.token;
}

async function queryStock(keyword, category) {
  let token = await getToken();
  let { status, json } = await req('POST', '/api/stock-query/search',
    { category: category || '', keyword: keyword || '' }, token);
  if (status === 401) {
    tokenCache.token = null;
    token = await getToken();
    ({ status, json } = await req('POST', '/api/stock-query/search',
      { category: category || '', keyword: keyword || '' }, token));
  }
  return json;
}

async function queryTrace(csn) {
  let token = await getToken();
  let { status, json } = await req('GET',
    '/api/sn-tracking/query?csn=' + encodeURIComponent(csn || ''), null, token);
  if (status === 401) {
    tokenCache.token = null;
    token = await getToken();
    ({ status, json } = await req('GET',
      '/api/sn-tracking/query?csn=' + encodeURIComponent(csn || ''), null, token));
  }
  return json;
}

function sendJSON(res, code, obj, corsOrigin) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': corsOrigin || '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function handle(req, res) {
  if (req.method === 'OPTIONS') { sendJSON(res, 204, {}); return; }
  const u = new URL(req.url, 'http://localhost');
  const p = u.pathname;
  const q = u.searchParams;
  if (p === '/stock' || p === '/api/stock') {
    queryStock(q.get('keyword'), q.get('category'))
      .then((json) => sendJSON(res, 200, json))
      .catch((e) => sendJSON(res, 502, { error: String(e && e.message || e) }));
    return;
  }
  if (p === '/trace' || p === '/api/trace') {
    queryTrace(q.get('csn'))
      .then((json) => sendJSON(res, 200, json))
      .catch((e) => sendJSON(res, 502, { error: String(e && e.message || e) }));
    return;
  }
  if (p === '/health') { sendJSON(res, 200, { ok: true }); return; }
  sendJSON(res, 404, { error: 'not found', paths: ['/stock?keyword=', '/trace?csn='] });
}

if (require.main === module) {
  const PORT = process.env.PORT || 8787;
  http.createServer(handle).listen(PORT, '127.0.0.1', () => {
    console.log('[kucun-proxy] listening on http://127.0.0.1:' + PORT + '  upstream=' + API_BASE);
  });
}

module.exports = { handle, queryStock, queryTrace };
