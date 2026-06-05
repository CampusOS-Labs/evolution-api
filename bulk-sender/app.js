const state = {
  validContacts: [],
  invalidContacts: [],
  isRunning: false,
};

const els = {
  baseUrl: document.getElementById('baseUrl'),
  instanceName: document.getElementById('instanceName'),
  apiKey: document.getElementById('apiKey'),
  message: document.getElementById('message'),
  minDelay: document.getElementById('minDelay'),
  maxDelay: document.getElementById('maxDelay'),
  timeout: document.getElementById('timeout'),
  validateBtn: document.getElementById('validateBtn'),
  sendBtn: document.getElementById('sendBtn'),
  summary: document.getElementById('summary'),
  log: document.getElementById('log'),
};

const contactIds = ['contact1', 'contact2', 'contact3', 'contact4', 'contact5'];

function getContacts() {
  return contactIds
    .map((id) => document.getElementById(id).value.trim())
    .map((number) => number.replace(/[\s()+-]/g, ''))
    .filter(Boolean);
}

function appendLog(message) {
  const now = new Date().toLocaleTimeString();
  els.log.textContent += `[${now}] ${message}\n`;
  els.log.scrollTop = els.log.scrollHeight;
}

function setSummary(text, isError = false) {
  els.summary.textContent = text;
  els.summary.classList.toggle('error', isError);
}

function setRunning(running) {
  state.isRunning = running;
  els.validateBtn.disabled = running;
  els.sendBtn.disabled = running;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function randomDelay(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function buildHeaders() {
  return {
    'Content-Type': 'application/json',
    apikey: els.apiKey.value.trim(),
  };
}

function getConfig() {
  const baseUrl = els.baseUrl.value.trim().replace(/\/$/, '');
  const instanceName = els.instanceName.value.trim();
  const apiKey = els.apiKey.value.trim();
  const text = els.message.value.trim();
  const minDelay = Number(els.minDelay.value);
  const maxDelay = Number(els.maxDelay.value);
  const timeout = Number(els.timeout.value);

  if (!baseUrl || !instanceName || !apiKey) {
    throw new Error('Base URL, Instance Name, and API Key are required.');
  }

  if (!text) {
    throw new Error('Announcement message is required.');
  }

  if (!Number.isFinite(minDelay) || !Number.isFinite(maxDelay) || minDelay < 1000 || maxDelay < minDelay) {
    throw new Error('Delay values are invalid. Make sure max delay is greater than or equal to min delay.');
  }

  if (!Number.isFinite(timeout) || timeout < 1000) {
    throw new Error('Timeout must be at least 1000ms.');
  }

  const contacts = getContacts();
  if (contacts.length === 0) {
    throw new Error('Please provide at least one contact.');
  }

  return { baseUrl, instanceName, text, minDelay, maxDelay, timeout, contacts };
}

async function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function validateContacts() {
  try {
    setRunning(true);
    setSummary('Validating contacts...');

    const cfg = getConfig();

    appendLog(`Validating ${cfg.contacts.length} contact(s)...`);

    const url = `${cfg.baseUrl}/chat/whatsappNumbers/${encodeURIComponent(cfg.instanceName)}`;

    const response = await fetchWithTimeout(
      url,
      {
        method: 'POST',
        headers: buildHeaders(),
        body: JSON.stringify({ numbers: cfg.contacts }),
      },
      cfg.timeout,
    );

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`Validation failed (${response.status}): ${bodyText}`);
    }

    const result = await response.json();
    state.validContacts = result.filter((item) => item.exists).map((item) => item.number);
    state.invalidContacts = result.filter((item) => !item.exists).map((item) => item.number);

    appendLog(`Valid: ${state.validContacts.length} -> ${state.validContacts.join(', ') || '-'}`);
    appendLog(`Invalid: ${state.invalidContacts.length} -> ${state.invalidContacts.join(', ') || '-'}`);

    setSummary(`Validation done. ${state.validContacts.length} valid, ${state.invalidContacts.length} invalid.`);
  } catch (error) {
    setSummary(error.message || 'Validation failed.', true);
    appendLog(`ERROR: ${error.message || String(error)}`);
  } finally {
    setRunning(false);
  }
}

async function sendToValidContacts() {
  try {
    setRunning(true);

    const cfg = getConfig();
    const targets = state.validContacts.length > 0 ? state.validContacts : cfg.contacts;

    if (targets.length === 0) {
      throw new Error('No valid contacts to send to. Run validation first or provide contacts.');
    }

    setSummary(`Sending to ${targets.length} contact(s)...`);
    appendLog(`Starting send batch to ${targets.length} contact(s).`);

    const endpoint = `${cfg.baseUrl}/message/sendText/${encodeURIComponent(cfg.instanceName)}`;
    const results = [];

    for (let i = 0; i < targets.length; i += 1) {
      const number = targets[i];
      appendLog(`Sending (${i + 1}/${targets.length}) -> ${number}`);

      try {
        const response = await fetchWithTimeout(
          endpoint,
          {
            method: 'POST',
            headers: buildHeaders(),
            body: JSON.stringify({ number, text: cfg.text }),
          },
          cfg.timeout,
        );

        if (!response.ok) {
          const errorText = await response.text();
          results.push({ number, ok: false, error: `HTTP ${response.status}: ${errorText}` });
          appendLog(`FAILED ${number}: HTTP ${response.status}`);
          appendLog(`Response body: ${errorText}`);
        } else {
          let bodyText = '';
          try {
            const cloned = response.clone();
            bodyText = await cloned.text();
            appendLog(`Response: ${bodyText}`);
          } catch (logErr) {
            appendLog(`Could not read response body: ${logErr.message || logErr}`);
          }
          results.push({ number, ok: true, responseBody: bodyText });
          appendLog(`SENT ${number}`);
        }
      } catch (error) {
        results.push({ number, ok: false, error: error.message || String(error) });
        appendLog(`FAILED ${number}: ${error.message || String(error)}`);
      }

      if (i < targets.length - 1) {
        const waitMs = randomDelay(cfg.minDelay, cfg.maxDelay);
        appendLog(`Waiting ${waitMs}ms before next send...`);
        await sleep(waitMs);
      }
    }

    const sentCount = results.filter((r) => r.ok).length;
    const failedCount = results.length - sentCount;
    setSummary(`Done. Sent: ${sentCount}, Failed: ${failedCount}`);

    if (failedCount > 0) {
      const failed = results.filter((r) => !r.ok);
      appendLog('Failed details:');
      failed.forEach((item) => appendLog(`- ${item.number}: ${item.error}`));
    }
  } catch (error) {
    setSummary(error.message || 'Sending failed.', true);
    appendLog(`ERROR: ${error.message || String(error)}`);
  } finally {
    setRunning(false);
  }
}

els.validateBtn.addEventListener('click', validateContacts);
els.sendBtn.addEventListener('click', sendToValidContacts);

appendLog('Tip: validate contacts first, then send.');
