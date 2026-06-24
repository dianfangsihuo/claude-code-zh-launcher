#!/usr/bin/env node
'use strict';

const assert = require('assert');
const http = require('http');
const { spawn } = require('child_process');
const path = require('path');

function listen(server) {
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

function requestJson(port, method, pathname, body) {
  return new Promise((resolve, reject) => {
    const raw = body ? JSON.stringify(body) : '';
    const req = http.request({
      host: '127.0.0.1',
      port,
      method,
      path: pathname,
      headers: {
        Authorization: 'Bearer local-deepseek-proxy',
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(raw)
      },
      timeout: 5000
    }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = {};
        try { json = text ? JSON.parse(text) : {}; } catch (error) { reject(error); return; }
        if (res.statusCode >= 400) {
          reject(new Error(`${res.statusCode}: ${text}`));
          return;
        }
        resolve(json);
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (raw) req.write(raw);
    req.end();
  });
}

async function startUpstream(captures, responseFactory) {
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      const payload = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      captures.push(payload);
      const response = responseFactory(payload, captures.length);
      const raw = JSON.stringify(response);
      res.writeHead(200, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(raw)
      });
      res.end(raw);
    });
  });
  return { server, port: await listen(server) };
}

async function startProxy(upstreamPort, providerName, reasoning) {
  const probe = http.createServer();
  const proxyPort = await listen(probe);
  await new Promise(resolve => probe.close(resolve));

  const proxyScript = path.join(__dirname, 'deepseek-claude-proxy.cjs');
  const child = spawn(process.execPath, [proxyScript], {
    cwd: path.dirname(__dirname),
    env: {
      ...process.env,
      DEEPSEEK_PROXY_PORT: String(proxyPort),
      PROVIDER_BASE_URL: `http://127.0.0.1:${upstreamPort}/v1`,
      PROVIDER_API_KEY: 'test-key',
      PROVIDER_MODEL: 'test-model',
      PROVIDER_NAME: providerName,
      PROVIDER_REASONING: reasoning
    },
    stdio: ['ignore', 'ignore', 'pipe']
  });

  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk.toString('utf8'); });
  for (let i = 0; i < 40; i++) {
    try {
      const health = await requestJson(proxyPort, 'GET', '/health');
      assert.strictEqual(health.reasoning, reasoning);
      return { child, proxyPort };
    } catch {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  child.kill('SIGKILL');
  throw new Error(`proxy did not start: ${stderr}`);
}

async function withProxy(providerName, reasoning, fn, responseFactory = defaultResponse) {
  const captures = [];
  const upstream = await startUpstream(captures, responseFactory);
  const proxy = await startProxy(upstream.port, providerName, reasoning);
  try {
    await fn(proxy.proxyPort, captures);
  } finally {
    proxy.child.kill('SIGKILL');
    await new Promise(resolve => upstream.server.close(resolve));
  }
}

function defaultResponse(payload) {
  return {
    id: 'chatcmpl_test',
    model: payload.model,
    choices: [{ message: { role: 'assistant', content: 'OK' }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 1, completion_tokens: 1 }
  };
}

function anthropicBody(extra = {}) {
  return {
    model: 'test-model',
    max_tokens: 64,
    messages: [{ role: 'user', content: 'hello' }],
    ...extra
  };
}

(async () => {
  await withProxy('deepseek', 'auto', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.ok(!captures[0].thinking, 'auto must not disable DeepSeek thinking');
    assert.ok(!captures[0].enable_thinking, 'auto must not set SiliconFlow thinking flag');
  });

  await withProxy('deepseek', 'off', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.deepStrictEqual(captures[0].thinking, { type: 'disabled' });
  });

  await withProxy('deepseek', 'max', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.strictEqual(captures[0].reasoning_effort, 'max');
  });

  await withProxy('siliconflow', 'off', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.strictEqual(captures[0].enable_thinking, false);
  });

  await withProxy('siliconflow', 'high', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.strictEqual(captures[0].enable_thinking, true);
  });

  await withProxy('openrouter', 'auto', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.deepStrictEqual(captures[0].reasoning, { enabled: true, exclude: false });
  });

  await withProxy('openrouter', 'max', async (port, captures) => {
    await requestJson(port, 'POST', '/v1/messages', anthropicBody());
    assert.deepStrictEqual(captures[0].reasoning, { effort: 'high', exclude: false });
    assert.strictEqual(captures[0].reasoning_effort, 'high');
  });

  await withProxy('deepseek', 'auto', async (port, captures) => {
    const first = await requestJson(port, 'POST', '/v1/messages', anthropicBody({
      tools: [{
        name: 'Echo',
        description: 'Echo input',
        input_schema: { type: 'object', properties: { value: { type: 'string' } } }
      }]
    }));
    await requestJson(port, 'POST', '/v1/messages', anthropicBody({
      messages: [
        { role: 'assistant', content: first.content },
        { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'call_1', content: '{"ok":true}' }] }
      ]
    }));
    const assistant = captures[1].messages.find(message => message.role === 'assistant');
    assert.strictEqual(assistant.reasoning_content, 'deep thought');
    assert.strictEqual(assistant.reasoning, 'router thought');
  }, (payload, count) => {
    if (count === 1) {
      return {
        id: 'chatcmpl_tool',
        model: payload.model,
        choices: [{
          message: {
            role: 'assistant',
            content: null,
            reasoning_content: 'deep thought',
            reasoning: 'router thought',
            tool_calls: [{
              id: 'call_1',
              type: 'function',
              function: { name: 'Echo', arguments: '{"value":"x"}' }
            }]
          },
          finish_reason: 'tool_calls'
        }],
        usage: { prompt_tokens: 1, completion_tokens: 1 }
      };
    }
    return defaultResponse(payload);
  });

  console.log('Proxy reasoning tests passed.');
})().catch(error => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
