// openchoreo-import client helper — auto-injected before </body> on every HTML
// response. Exposes window.OC = { toast, copy }.
(function () {
  'use strict';

  function ensureToast() {
    if (document.getElementById('oc-toast')) return;
    const style = document.createElement('style');
    style.textContent =
      '.oc-toast{position:fixed;top:64px;right:1rem;background:#0f172a;color:#fff;padding:.65rem 1rem;' +
      'border-radius:8px;font-family:SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono","Courier New",monospace;' +
      'font-size:.75rem;transform:translateX(calc(100% + 2rem));' +
      'transition:transform .3s cubic-bezier(.22,.6,.16,1);z-index:1000;pointer-events:none}' +
      '.oc-toast.show{transform:translateX(0)}';
    document.head.appendChild(style);
    const div = document.createElement('div');
    div.id = 'oc-toast';
    div.className = 'oc-toast';
    document.body.appendChild(div);
  }
  let toastTimer;
  function toast(msg) {
    ensureToast();
    const el = document.getElementById('oc-toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 1900);
  }

  async function copy(text, msg) {
    try {
      await navigator.clipboard.writeText(text);
      toast(msg || 'Copied');
      return true;
    } catch (e) {
      toast('Could not copy');
      return false;
    }
  }

  let ws = null;
  function connect() {
    try {
      const wsProto = window.location.protocol === 'https:' ? 'wss://' : 'ws://';
      ws = new WebSocket(wsProto + window.location.host);
    } catch (e) {
      setTimeout(connect, 1500);
      return;
    }
    ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg && msg.type === 'reload') window.location.reload();
    };
    ws.onclose = () => setTimeout(connect, 1000);
    ws.onerror = () => { try { ws.close(); } catch (e) {} };
  }

  document.addEventListener('click', (e) => {
    const local = e.target.closest('[data-local]');
    if (local) {
      e.preventDefault();
      handleLocal(local);
    }
  });

  function handleLocal(el) {
    if (el.dataset.local === 'copy-plan') {
      fetch('/plan.md').then((r) => {
        if (!r.ok) { toast('plan.md not available'); return; }
        r.text().then((t) => copy(t, 'plan.md copied'));
      }).catch(() => toast('Could not fetch plan.md'));
    }
  }

  document.querySelectorAll('details.plan-preview').forEach((d) => {
    let slot = d.querySelector('.preview-slot');
    if (!slot) {
      slot = document.createElement('div');
      slot.className = 'preview-slot';
      d.appendChild(slot);
    }
    d.addEventListener('toggle', async () => {
      if (!d.open || d.dataset.loaded) return;
      d.dataset.loaded = '1';
      slot.innerHTML = '<div class="loading">Loading plan.md…</div>';
      try {
        const r = await fetch('/plan.md');
        if (!r.ok) throw new Error('not found');
        const text = await r.text();
        slot.innerHTML = '';
        const pre = document.createElement('pre');
        pre.textContent = text;
        slot.appendChild(pre);
        attachCopy(pre);
      } catch (e) {
        slot.innerHTML =
          '<div class="loading">plan.md not available yet — it is written when the plan is finalized.</div>';
        delete d.dataset.loaded;
      }
    });
  });

  document.querySelectorAll('[data-fill]').forEach((filler) => {
    const target = document.querySelector('[data-slot="' + filler.dataset.fill + '"]');
    if (!target) return;
    while (filler.firstChild) target.appendChild(filler.firstChild);
    filler.remove();
  });

  document.querySelectorAll('.tabs').forEach((tabs) => {
    tabs.querySelectorAll('.tab-pane[data-tab]').forEach((pane) => {
      if (pane.children.length || pane.textContent.trim()) return;
      const navBtn = tabs.querySelector('.tabs-nav button[data-tab="' + pane.dataset.tab + '"]');
      if (navBtn) navBtn.remove();
      pane.remove();
    });
  });

  // Activate the first tab before the diagram renders, so its pane has real
  // dimensions when the cell-diagram measures it.
  document.querySelectorAll('.tabs').forEach((tabs) => {
    const btns = tabs.querySelectorAll('.tabs-nav button[data-tab]');
    const panes = tabs.querySelectorAll('.tab-pane[data-tab]');
    btns.forEach((b) => b.addEventListener('click', () => {
      const id = b.dataset.tab;
      btns.forEach((x) => x.classList.toggle('active', x.dataset.tab === id));
      panes.forEach((p) => p.classList.toggle('active', p.dataset.tab === id));
    }));
    if (btns.length && !tabs.querySelector('.tabs-nav button.active')) btns[0].click();
  });

  (function renderCellDiagram() {
    const modelEl = document.querySelector('[data-cell-model]');
    if (!modelEl) return;
    const pane = document.querySelector('.tab-pane[data-tab="architecture"]') || modelEl.parentElement;
    let host = pane.querySelector('.cd-host');
    if (!host) { host = document.createElement('div'); host.className = 'cd-host'; pane.appendChild(host); }

    let spec;
    try { spec = JSON.parse(modelEl.textContent); }
    catch (e) { host.innerHTML = '<div class="cd-error">Invalid architecture model JSON:\n' + e.message + '</div>'; return; }

    let tries = 0;
    (function waitForLib() {
      if (window.cellDiagram && window.cellDiagram.renderCellDiagram) {
        try { window.cellDiagram.renderCellDiagram(spec, host); }
        catch (e) { host.innerHTML = '<div class="cd-error">Diagram render failed:\n' + (e && e.message) + '</div>'; }
      } else if (tries++ < 100) {
        setTimeout(waitForLib, 50);
      } else {
        host.innerHTML = '<div class="cd-error">cell-diagram library did not load.</div>';
      }
    })();
  })();

  function attachCopy(pre) {
    if (pre.querySelector('.copy-pre')) return;
    const btn = document.createElement('button');
    btn.className = 'copy-pre';
    btn.textContent = 'Copy';
    btn.addEventListener('click', async (e) => {
      e.preventDefault();
      const text = (pre.querySelector('code') || pre).innerText;
      const ok = await copy(text);
      if (!ok) return;
      btn.textContent = 'Copied';
      btn.classList.add('copied');
      setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1400);
    });
    pre.appendChild(btn);
  }
  document.querySelectorAll('.doc pre').forEach(attachCopy);

  window.OC = { toast, copy };

  connect();
})();
