/* ============================================================
   NeuralChat — AI Inference POC
   Frontend Application Logic
   ============================================================ */

// ---- Model Configuration ----
const MODELS = {
  'llama3.2:1b': {
    name: 'Llama 3.2 1B',
    group: 'Tiny',
    size: '0.8 GB',
    instance: 't3.large',
    estTime: '2–4 min',
    vision: false,
    description: 'Ultra-fast, great for simple tasks'
  },
  'phi3:mini': {
    name: 'Phi-3 Mini 3.8B',
    group: 'Tiny',
    size: '2.3 GB',
    instance: 't3.large',
    estTime: '3–5 min',
    vision: false,
    description: 'Microsoft Phi-3, small but capable'
  },
  'llama3.2:3b': {
    name: 'Llama 3.2 3B',
    group: 'Small',
    size: '2.0 GB',
    instance: 't3.xlarge',
    estTime: '3–5 min',
    vision: false,
    description: 'Good balance of speed and quality'
  },
  'gemma2:2b': {
    name: 'Gemma 2 2B',
    group: 'Small',
    size: '1.6 GB',
    instance: 't3.large',
    estTime: '2–4 min',
    vision: false,
    description: "Google's Gemma 2, efficient 2B"
  },
  'mistral:7b': {
    name: 'Mistral 7B',
    group: 'Medium',
    size: '4.1 GB',
    instance: 't3.2xlarge',
    estTime: '5–8 min',
    vision: false,
    description: 'High quality French model, widely used'
  },
  'llama3.1:8b': {
    name: 'Llama 3.1 8B',
    group: 'Medium',
    size: '4.9 GB',
    instance: 't3.2xlarge',
    estTime: '5–8 min',
    vision: false,
    description: "Meta's Llama 3.1, excellent quality"
  },
  'llava:7b': {
    name: 'LLaVA 7B',
    group: 'Medium',
    size: '4.5 GB',
    instance: 't3.2xlarge',
    estTime: '5–8 min',
    vision: true,
    description: 'Multimodal — understands images + text'
  },
  'llama3.1:70b': {
    name: 'Llama 3.1 70B',
    group: 'Large',
    size: '40+ GB',
    instance: 'r5.2xlarge',
    estTime: '12–18 min',
    vision: false,
    description: 'Most capable, 70B parameters'
  },
  'mixtral:8x7b': {
    name: 'Mixtral 8x7B',
    group: 'Large',
    size: '26 GB',
    instance: 'r5.xlarge',
    estTime: '10–15 min',
    vision: false,
    description: 'Mixture of Experts, high quality'
  }
};

// ---- App State ----
const state = {
  lambdaUrl: '',
  region: 'us-east-1',
  currentModel: 'llama3.2:3b',
  messages: [],
  conversations: [],
  currentConversationId: null,
  isLoading: false,
  uploadedImage: null,
  uploadedImageName: '',
  theme: 'dark'
};

// ---- Init ----
function init() {
  loadFromStorage();
  updateModelInfo(state.currentModel);
  updateConnectionStatus();
  checkWelcomeWarning();
  renderHistory();
  updateSendButton();
  setupDragDrop();
  setupMarked();
  document.getElementById('promptInput').addEventListener('input', function () {
    updateSendButton();
    updateCharCount();
  });
}

function setupMarked() {
  if (window.marked) {
    marked.setOptions({
      highlight: function (code, lang) {
        if (window.hljs) {
          try {
            const language = hljs.getLanguage(lang) ? lang : 'plaintext';
            return hljs.highlight(code, { language }).value;
          } catch {
            return hljs.highlightAuto(code).value;
          }
        }
        return code;
      },
      breaks: true,
      gfm: true
    });
  }
}

// ---- Storage ----
function loadFromStorage() {
  const cfg = JSON.parse(localStorage.getItem('neuralchat_config') || '{}');
  state.lambdaUrl = cfg.lambdaUrl || '';
  state.region = cfg.region || 'us-east-1';
  state.theme = cfg.theme || 'dark';
  state.currentModel = cfg.currentModel || 'llama3.2:3b';
  state.conversations = JSON.parse(localStorage.getItem('neuralchat_history') || '[]');

  applyTheme(state.theme);

  const modelSelect = document.getElementById('modelSelect');
  if (modelSelect) modelSelect.value = state.currentModel;

  const regionInput = document.getElementById('regionInput');
  if (regionInput) regionInput.value = state.region;
}

function saveToStorage() {
  localStorage.setItem('neuralchat_config', JSON.stringify({
    lambdaUrl: state.lambdaUrl,
    region: state.region,
    theme: state.theme,
    currentModel: state.currentModel
  }));
  localStorage.setItem('neuralchat_history', JSON.stringify(state.conversations));
}

// ---- Theme ----
function applyTheme(theme) {
  document.body.classList.toggle('light', theme === 'light');
  document.querySelectorAll('.theme-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.theme === theme);
  });
  state.theme = theme;
}

// ---- Model Selection ----
function selectModel(modelId) {
  state.currentModel = modelId;
  updateModelInfo(modelId);
  const model = MODELS[modelId];
  const badge = document.getElementById('currentModelBadge');
  if (badge) badge.textContent = model ? model.name : modelId;
  saveToStorage();
}

function updateModelInfo(modelId) {
  const model = MODELS[modelId];
  if (!model) return;
  const setEl = (id, val) => {
    const el = document.getElementById(id);
    if (el) el.textContent = val;
  };
  setEl('modelSize', model.size);
  setEl('modelInstance', model.instance);
  setEl('modelTime', model.estTime);
  setEl('modelVision', model.vision ? 'Yes ✓' : 'No');
  const badge = document.getElementById('currentModelBadge');
  if (badge) badge.textContent = model.name;
}

// ---- Connection Status ----
function updateConnectionStatus() {
  const el = document.getElementById('connectionStatus');
  if (!el) return;
  if (state.lambdaUrl) {
    el.classList.add('connected');
    el.querySelector('.status-text').textContent = 'Connected';
  } else {
    el.classList.remove('connected');
    el.querySelector('.status-text').textContent = 'Disconnected';
  }
}

function checkWelcomeWarning() {
  const warning = document.getElementById('urlWarning');
  if (warning) warning.style.display = state.lambdaUrl ? 'none' : 'flex';
}

// ---- Settings Modal ----
function openSettings() {
  const modal = document.getElementById('settingsModal');
  modal.classList.remove('hidden');
  const urlInput = document.getElementById('lambdaUrlInput');
  if (urlInput) urlInput.value = state.lambdaUrl;
  const regionInput = document.getElementById('regionInput');
  if (regionInput) regionInput.value = state.region;

  document.querySelectorAll('.theme-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.theme === state.theme);
    btn.onclick = () => applyTheme(btn.dataset.theme);
  });
}

function closeSettings() {
  document.getElementById('settingsModal').classList.add('hidden');
}

function saveSettings() {
  const urlInput = document.getElementById('lambdaUrlInput');
  const regionInput = document.getElementById('regionInput');
  state.lambdaUrl = (urlInput?.value || '').trim();
  state.region = regionInput?.value || 'us-east-1';
  saveToStorage();
  updateConnectionStatus();
  checkWelcomeWarning();
  closeSettings();
  showToast('Settings saved', 'success');
}

// Close modal on overlay click
document.getElementById('settingsModal').addEventListener('click', function (e) {
  if (e.target === this) closeSettings();
});

// ---- Image Upload ----
function handleImageUpload(event) {
  const file = event.target.files[0];
  if (!file) return;
  processImageFile(file);
  event.target.value = '';
}

function processImageFile(file) {
  if (!file.type.startsWith('image/')) {
    showToast('Please upload an image file', 'error');
    return;
  }
  if (file.size > 10 * 1024 * 1024) {
    showToast('Image must be under 10MB', 'error');
    return;
  }
  const reader = new FileReader();
  reader.onload = (e) => {
    state.uploadedImage = e.target.result;
    state.uploadedImageName = file.name;
    showImagePreview(e.target.result, file.name, file.size);
    updateSendButton();
  };
  reader.readAsDataURL(file);
}

function showImagePreview(src, name, size) {
  const bar = document.getElementById('imagePreviewBar');
  const img = document.getElementById('imagePreviewImg');
  const nameEl = document.getElementById('imagePreviewName');
  const sizeEl = document.getElementById('imagePreviewSize');
  if (bar) bar.style.display = 'block';
  if (img) img.src = src;
  if (nameEl) nameEl.textContent = name;
  if (sizeEl) sizeEl.textContent = formatBytes(size);
}

function removeImage() {
  state.uploadedImage = null;
  state.uploadedImageName = '';
  const bar = document.getElementById('imagePreviewBar');
  if (bar) bar.style.display = 'none';
  updateSendButton();
}

function setupDragDrop() {
  const inputBox = document.getElementById('inputBox');
  if (!inputBox) return;

  inputBox.addEventListener('dragover', (e) => {
    e.preventDefault();
    inputBox.classList.add('drag-over');
  });

  inputBox.addEventListener('dragleave', () => {
    inputBox.classList.remove('drag-over');
  });

  inputBox.addEventListener('drop', (e) => {
    e.preventDefault();
    inputBox.classList.remove('drag-over');
    const file = e.dataTransfer.files[0];
    if (file && file.type.startsWith('image/')) {
      processImageFile(file);
    }
  });
}

// ---- Input Helpers ----
function autoResize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 200) + 'px';
}

function handleKeydown(e) {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendMessage();
  }
}

function updateSendButton() {
  const btn = document.getElementById('sendBtn');
  const input = document.getElementById('promptInput');
  if (!btn || !input) return;
  const hasContent = input.value.trim().length > 0 || state.uploadedImage;
  btn.disabled = !hasContent || state.isLoading;
}

function updateCharCount() {
  const input = document.getElementById('promptInput');
  const counter = document.getElementById('charCount');
  if (input && counter) counter.textContent = input.value.length;
}

function useSuggestion(text) {
  const input = document.getElementById('promptInput');
  if (input) {
    input.value = text;
    autoResize(input);
    updateSendButton();
    updateCharCount();
    input.focus();
  }
}

// ---- Chat / Conversation Management ----
function newConversation() {
  if (state.messages.length > 0) {
    saveConversation();
  }
  state.messages = [];
  state.currentConversationId = generateId();
  const msgContainer = document.getElementById('messagesContainer');
  if (msgContainer) msgContainer.innerHTML = '';
  document.getElementById('welcomeScreen').style.display = 'flex';
}

function saveConversation() {
  if (state.messages.length === 0) return;
  const firstMsg = state.messages.find(m => m.role === 'user');
  const title = firstMsg
    ? firstMsg.content.substring(0, 50) + (firstMsg.content.length > 50 ? '...' : '')
    : 'New conversation';

  const existing = state.conversations.findIndex(c => c.id === state.currentConversationId);
  const conv = {
    id: state.currentConversationId || generateId(),
    title,
    messages: [...state.messages],
    timestamp: Date.now()
  };

  if (existing >= 0) {
    state.conversations[existing] = conv;
  } else {
    state.conversations.unshift(conv);
    if (state.conversations.length > 20) state.conversations.pop();
  }
  saveToStorage();
  renderHistory();
}

function loadConversation(id) {
  const conv = state.conversations.find(c => c.id === id);
  if (!conv) return;
  state.messages = [...conv.messages];
  state.currentConversationId = id;
  document.getElementById('welcomeScreen').style.display = 'none';
  const msgContainer = document.getElementById('messagesContainer');
  msgContainer.innerHTML = '';
  conv.messages.forEach(msg => {
    if (msg.role === 'user') {
      appendUserMessage(msg.content, msg.image);
    } else if (msg.role === 'assistant') {
      appendAssistantMessage(msg.content, msg.timing);
    }
  });
  scrollToBottom();
  renderHistory();
}

function deleteConversation(id, event) {
  event.stopPropagation();
  state.conversations = state.conversations.filter(c => c.id !== id);
  if (state.currentConversationId === id) {
    newConversation();
  }
  saveToStorage();
  renderHistory();
}

function renderHistory() {
  const container = document.getElementById('chatHistory');
  if (!container) return;
  if (state.conversations.length === 0) {
    container.innerHTML = '<div class="empty-history">No conversations yet</div>';
    return;
  }
  container.innerHTML = state.conversations.map(conv => `
    <div class="history-item ${conv.id === state.currentConversationId ? 'active' : ''}" onclick="loadConversation('${conv.id}')">
      <svg class="history-item-icon" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
      </svg>
      <span class="history-item-text">${escapeHtml(conv.title)}</span>
      <button class="history-delete" onclick="deleteConversation('${conv.id}', event)" title="Delete">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
          <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
    </div>
  `).join('');
}

// ---- Send Message ----
async function sendMessage() {
  const input = document.getElementById('promptInput');
  if (!input) return;
  const prompt = input.value.trim();
  const image = state.uploadedImage;

  if (!prompt && !image) return;
  if (state.isLoading) return;

  if (!state.lambdaUrl) {
    openSettings();
    showToast('Please configure your Lambda URL first', 'error');
    return;
  }

  // Hide welcome screen
  document.getElementById('welcomeScreen').style.display = 'none';

  // Clear input
  input.value = '';
  autoResize(input);
  updateCharCount();

  // Store message
  const userMsg = { role: 'user', content: prompt, image: image || null };
  state.messages.push(userMsg);

  // Render user message
  appendUserMessage(prompt, image);
  removeImage();

  // Set loading state
  state.isLoading = true;
  updateSendButton();
  showInferenceLoader();

  let elapsedInterval = startElapsedTimer();

  try {
    const payload = {
      model: state.currentModel,
      prompt: prompt || '',
      image: image ? image.split(',')[1] : null // Send only base64 data, not data URL
    };

    const response = await fetch(state.lambdaUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Lambda returned ${response.status}: ${errText}`);
    }

    const data = await response.json();

    // Handle Lambda proxy response format
    const body = typeof data.body === 'string' ? JSON.parse(data.body) : data;
    const aiResponse = body.response || body.message || 'No response received';
    const timing = body.timing || null;

    // Show real timings on each loader step briefly before hiding
    applyRealTimings(timing);

    // Store assistant message
    state.messages.push({ role: 'assistant', content: aiResponse, timing });

    // Brief pause so the user sees the real per-step timings populate
    await new Promise(r => setTimeout(r, 700));

    // Render response
    appendAssistantMessage(aiResponse, timing);
    saveConversation();

  } catch (err) {
    console.error('Inference error:', err);
    appendErrorMessage(err.message);
    state.messages.push({ role: 'assistant', content: `Error: ${err.message}`, timing: null });
  } finally {
    clearInterval(elapsedInterval);
    state.isLoading = false;
    hideInferenceLoader();
    updateSendButton();
    scrollToBottom();
  }
}

// ---- Message Rendering ----
function appendUserMessage(content, imageDataUrl) {
  const container = document.getElementById('messagesContainer');
  if (!container) return;

  const wrapper = document.createElement('div');
  wrapper.className = 'message-wrapper user';

  const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  wrapper.innerHTML = `
    <div class="message-meta">
      <div class="avatar user-avatar">U</div>
      <span>${now}</span>
    </div>
    <div class="message-bubble">
      ${imageDataUrl ? `<img src="${escapeHtml(imageDataUrl)}" class="message-image" alt="Uploaded image" />` : ''}
      ${content ? `<div>${escapeHtml(content)}</div>` : ''}
    </div>
    <div class="message-actions">
      <button class="message-action-btn" onclick="copyText(${JSON.stringify(content)})">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
        </svg>
        Copy
      </button>
    </div>
  `;
  container.appendChild(wrapper);
  scrollToBottom();
}

function appendAssistantMessage(content, timing) {
  const container = document.getElementById('messagesContainer');
  if (!container) return;

  const wrapper = document.createElement('div');
  wrapper.className = 'message-wrapper assistant';

  const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const model = MODELS[state.currentModel];

  const renderedContent = renderMarkdown(content);

  wrapper.innerHTML = `
    <div class="message-meta">
      <div class="avatar ai-avatar">AI</div>
      <span>${model ? model.name : state.currentModel}</span>
      <span>${now}</span>
    </div>
    <div class="message-bubble">${renderedContent}</div>
    <div class="message-actions">
      <button class="message-action-btn" onclick="copyText(${JSON.stringify(content)})">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
        </svg>
        Copy
      </button>
    </div>
    ${timing ? renderTimingCard(timing) : ''}
  `;

  container.appendChild(wrapper);

  // Highlight code blocks
  wrapper.querySelectorAll('pre code').forEach(block => {
    if (window.hljs) hljs.highlightElement(block);
    // Add header to code block
    const pre = block.parentElement;
    const lang = block.className.replace('language-', '').replace('hljs', '').trim() || 'code';
    const header = document.createElement('div');
    header.className = 'code-block-header';
    header.innerHTML = `
      <span>${lang}</span>
      <button class="copy-code-btn" onclick="copyText(${JSON.stringify(block.textContent)})">Copy</button>
    `;
    pre.insertBefore(header, block);
  });

  scrollToBottom();
}

function appendErrorMessage(errorText) {
  const container = document.getElementById('messagesContainer');
  if (!container) return;

  const div = document.createElement('div');
  div.className = 'message-wrapper assistant';
  div.innerHTML = `
    <div class="message-meta">
      <div class="avatar ai-avatar">AI</div>
      <span>Error</span>
    </div>
    <div class="error-message">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="flex-shrink:0">
        <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
      </svg>
      <div>
        <div style="font-weight:600;margin-bottom:2px;">Inference Failed</div>
        <div style="opacity:0.8;font-size:12px;">${escapeHtml(errorText)}</div>
      </div>
    </div>
  `;
  container.appendChild(div);
  scrollToBottom();
}

function renderTimingCard(timing) {
  const total = timing.total_seconds || 0;
  const ec2 = timing.ec2_startup_seconds || 0;
  const server = timing.server_ready_seconds || 0;
  const inference = timing.inference_seconds || 0;

  const pct = (v) => total > 0 ? Math.round((v / total) * 100) : 0;

  return `
    <div class="timing-card">
      <div class="timing-card-header">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>
        </svg>
        Timing Breakdown
        <span class="timing-total">${total}s total</span>
      </div>
      <div class="timing-rows">
        ${timingRow('EC2 Startup', ec2, pct(ec2), '#8b5cf6')}
        ${timingRow('Server Ready', server, pct(server), '#3b82f6')}
        ${timingRow('Inference', inference, pct(inference), '#10b981')}
      </div>
    </div>
  `;
}

function timingRow(label, seconds, pct, color) {
  return `
    <div class="timing-row">
      <span class="timing-label">${label}</span>
      <div class="timing-bar-track">
        <div class="timing-bar-fill" style="width:${pct}%;background:${color};"></div>
      </div>
      <span class="timing-value">${seconds}s</span>
    </div>
  `;
}

function renderMarkdown(text) {
  if (!window.marked) return escapeHtml(text).replace(/\n/g, '<br>');
  try {
    return marked.parse(text);
  } catch {
    return escapeHtml(text);
  }
}

// ---- Inference Loader ----
let loaderTimerStart = null;
let loaderTimerInterval = null;
let stageTimers = [];

// Per-model rough stage estimates (seconds): lambda init, EC2 boot, server ready, inference
function getStageEstimates(modelId) {
  const m = MODELS[modelId];
  const group = m ? m.group : 'Small';
  if (group === 'Tiny')   return { lambda: 5, ec2: 150, server: 20, inference: 15 };
  if (group === 'Small')  return { lambda: 5, ec2: 150, server: 40, inference: 30 };
  if (group === 'Medium') return { lambda: 5, ec2: 150, server: 90, inference: 90 };
  if (group === 'Large')  return { lambda: 5, ec2: 180, server: 180, inference: 540 };
  return { lambda: 5, ec2: 150, server: 60, inference: 30 };
}

function formatStepTime(secs) {
  if (secs == null) return '—';
  if (secs < 60) return Math.round(secs) + 's';
  const m = Math.floor(secs / 60);
  const s = Math.round(secs % 60);
  return s > 0 ? `${m}m ${s}s` : `${m}m`;
}

function showInferenceLoader() {
  const loader = document.getElementById('inferenceLoader');
  if (loader) loader.style.display = 'flex';
  loaderTimerStart = Date.now();

  // Reset all steps
  ['step1', 'step2', 'step3', 'step4'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.classList.remove('active', 'done');
  });
  ['step1Timer', 'step2Timer', 'step3Timer', 'step4Timer'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = id === 'step1Timer' ? '0s' : '—';
  });

  // Show ETA from estimates
  const est = getStageEstimates(state.currentModel);
  const totalEst = est.lambda + est.ec2 + est.server + est.inference;
  const etaEl = document.getElementById('loaderEta');
  if (etaEl) {
    const lo = Math.round(totalEst / 60);
    const hi = Math.ceil((totalEst * 1.4) / 60);
    etaEl.textContent = `~${lo}–${hi} min`;
  }

  // Activate step 1 immediately
  activateStep('step1');

  // Schedule progressive step transitions based on estimates
  stageTimers.forEach(t => clearTimeout(t));
  stageTimers = [];
  let cumulative = 0;

  cumulative += est.lambda * 1000;
  stageTimers.push(setTimeout(() => {
    completeStep('step1', formatStepTime(est.lambda));
    activateStep('step2');
  }, cumulative));

  cumulative += est.ec2 * 1000;
  stageTimers.push(setTimeout(() => {
    completeStep('step2', formatStepTime(est.ec2));
    activateStep('step3');
  }, cumulative));

  cumulative += est.server * 1000;
  stageTimers.push(setTimeout(() => {
    completeStep('step3', formatStepTime(est.server));
    activateStep('step4');
  }, cumulative));
  // Step 4 stays active until response arrives
}

function activateStep(stepId) {
  const el = document.getElementById(stepId);
  if (el) {
    el.classList.add('active');
    const icon = el.querySelector('.step-icon');
    if (icon) icon.classList.add('spinning');
  }
}

function completeStep(stepId, timeValue) {
  const el = document.getElementById(stepId);
  if (el) {
    el.classList.remove('active');
    el.classList.add('done');
    const icon = el.querySelector('.step-icon');
    if (icon) icon.classList.remove('spinning');
    const timer = document.getElementById(stepId + 'Timer');
    if (timer) timer.textContent = timeValue;
  }
}

// Populate real timings on each step (called when Lambda response arrives)
function applyRealTimings(timing) {
  if (!timing) return;
  stageTimers.forEach(t => clearTimeout(t));
  stageTimers = [];
  completeStep('step1', '✓');
  completeStep('step2', formatStepTime(timing.ec2_startup_seconds));
  completeStep('step3', formatStepTime(timing.server_ready_seconds));
  completeStep('step4', formatStepTime(timing.inference_seconds));
}

function hideInferenceLoader() {
  stageTimers.forEach(t => clearTimeout(t));
  stageTimers = [];
  const loader = document.getElementById('inferenceLoader');
  if (loader) loader.style.display = 'none';
  if (loaderTimerInterval) {
    clearInterval(loaderTimerInterval);
    loaderTimerInterval = null;
  }
}

function startElapsedTimer() {
  const elapsed = document.getElementById('loaderElapsed');
  return setInterval(() => {
    if (loaderTimerStart && elapsed) {
      const secs = ((Date.now() - loaderTimerStart) / 1000).toFixed(1);
      elapsed.textContent = secs + 's';
    }
  }, 100);
}

// ---- Sidebar Toggle ----
function toggleSidebar() {
  const sidebar = document.getElementById('sidebar');
  if (sidebar) sidebar.classList.toggle('collapsed');
}

// ---- Utilities ----
function scrollToBottom() {
  const chatArea = document.getElementById('chatArea');
  if (chatArea) {
    setTimeout(() => chatArea.scrollTo({ top: chatArea.scrollHeight, behavior: 'smooth' }), 50);
  }
}

function escapeHtml(text) {
  if (!text) return '';
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

function generateId() {
  return Date.now().toString(36) + Math.random().toString(36).substring(2, 9);
}

function copyText(text) {
  navigator.clipboard.writeText(text).then(() => {
    showToast('Copied to clipboard', 'success');
  }).catch(() => {
    showToast('Could not copy text', 'error');
  });
}

function showToast(message, type = '') {
  let toast = document.querySelector('.toast');
  if (!toast) {
    toast = document.createElement('div');
    toast.className = 'toast';
    document.body.appendChild(toast);
  }
  toast.textContent = message;
  toast.className = `toast ${type}`;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 2500);
}

// ---- Init on load ----
document.addEventListener('DOMContentLoaded', init);
