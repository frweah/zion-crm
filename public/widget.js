/*
 * Zion Vocational Rehab — the website chat bubble (Messaging brief, C).
 *
 * One line on zionrehabcenter.com:
 *
 *   <script src="https://crm.zionvocrehab.com/widget.js" async></script>
 *
 * It asks for nothing until somebody clicks it: no framework, no fonts, no
 * network call on page load beyond this file, and everything it draws lives
 * in a shadow root so the website's stylesheet and this cannot break each
 * other. Nothing is stored but a token, in sessionStorage, which is gone when
 * the tab closes - there are no cookies here.
 *
 * It names its own colours rather than the CRM's tokens, because it is not
 * drawn on the CRM: it is drawn on somebody else's page, which has its own
 * everything. The pairs below were checked the same way the CRM's are -
 * #1f1d1a on #fbfaf7 is 15.8:1, #7f6437 on #fbfaf7 is 5.2:1, and #1f1d1a on
 * the gold #c9a46b is 8.0:1.
 *
 * Accessibility is not a later pass: the launcher and the panel are real
 * buttons and a real dialog, every field has a label, replies are announced,
 * Escape closes it and puts the focus back where it was, and nobody who has
 * asked their device for less motion gets any.
 */
(function () {
  "use strict";
  var script = document.currentScript;
  if (!script || window.__zionChatLoaded) return;
  window.__zionChatLoaded = true;

  var BASE = new URL(script.src).origin;
  var CONSENT =
    "By chatting you agree to be contacted at the number or address you give us.";
  var KEY = "zion-chat-token";

  var state = { open: false, token: null, since: 0, timer: null, started: false, config: null };

  // ── the panel ──────────────────────────────────────────────
  var host = document.createElement("div");
  host.setAttribute("data-zion-chat", "");
  var root = host.attachShadow({ mode: "open" });
  root.innerHTML =
    '<style>' +
    ':host,*{box-sizing:border-box}' +
    '.wrap{position:fixed;right:16px;bottom:16px;z-index:2147483000;font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;color:#1f1d1a}' +
    '.launch{display:flex;align-items:center;gap:8px;min-height:48px;padding:0 20px;border:0;border-radius:999px;background:#c9a46b;color:#1f1d1a;font:inherit;font-weight:600;cursor:pointer;box-shadow:0 2px 10px rgba(31,29,26,.28);transition:background 200ms ease-in-out}' +
    '.launch:hover{background:#b8935a}' +
    '.launch:focus-visible,.panel :focus-visible{outline:3px solid #7f6437;outline-offset:2px}' +
    '.panel{display:none;flex-direction:column;width:340px;max-width:calc(100vw - 32px);max-height:min(560px,calc(100vh - 32px));background:#fbfaf7;border:1px solid #cfc9bf;border-radius:12px;box-shadow:0 8px 28px rgba(31,29,26,.28);overflow:hidden}' +
    '.panel[data-open="yes"]{display:flex}' +
    '.wrap[data-open="yes"] .launch{display:none}' +
    '.head{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:12px 14px;background:#1f1d1a;color:#e9e5dc}' +
    '.head h2{margin:0;font-size:15px;font-weight:600}' +
    '.head .said{display:block;font-size:12px;color:#b3ac9f;font-weight:400}' +
    '.x{border:0;background:none;color:#e9e5dc;font-size:20px;line-height:1;padding:4px 6px;cursor:pointer;border-radius:6px}' +
    '.x:hover{background:#2a2824}' +
    '.body{flex:1;overflow-y:auto;padding:12px 14px;display:flex;flex-direction:column;gap:8px}' +
    '.msg{max-width:88%;padding:8px 11px;border-radius:10px;background:#f0ece3;overflow-wrap:anywhere;white-space:pre-wrap}' +
    '.msg.you{align-self:flex-end;background:#f3ecdd}' +
    '.msg.system{align-self:stretch;max-width:100%;background:none;border:1px dashed #cfc9bf;color:#3a3733;font-size:13px}' +
    '.from{display:block;font-size:12px;color:#5d584f;margin-bottom:2px}' +
    '.foot{border-top:1px solid #e4e0d8;padding:10px 14px}' +
    'label{display:block;font-size:12px;color:#5d584f;margin:0 0 3px}' +
    'input,textarea{width:100%;padding:8px 10px;border:1px solid #8c857a;border-radius:8px;background:#fff;color:#1f1d1a;font:inherit}' +
    'textarea{resize:vertical;min-height:62px}' +
    '.field+.field{margin-top:8px}' +
    '.go{width:100%;min-height:44px;margin-top:10px;border:0;border-radius:8px;background:#c9a46b;color:#1f1d1a;font:inherit;font-weight:600;cursor:pointer;transition:background 200ms ease-in-out}' +
    '.go:hover{background:#b8935a}' +
    '.go[disabled]{background:#e4e0d8;color:#3a3733;cursor:default}' +
    '.note{margin:8px 0 0;font-size:12px;color:#5d584f}' +
    '.bad{margin:0 0 8px;padding:8px 10px;border-left:3px solid #a24e3b;background:#f6e6e1;font-size:13px}' +
    '.hp{position:absolute;left:-9999px;width:1px;height:1px;overflow:hidden}' +
    '@media (prefers-reduced-motion: reduce){.launch,.go{transition:none}}' +
    '</style>' +
    '<div class="wrap" data-open="no">' +
    '<button class="launch" type="button" aria-haspopup="dialog">' +
    '<span aria-hidden="true">💬</span><span class="launch-text">Chat with us</span></button>' +
    '<section class="panel" role="dialog" aria-label="Chat with Zion Vocational Rehab" data-open="no">' +
    '<div class="head"><h2>Zion Vocational Rehab<span class="said"></span></h2>' +
    '<button class="x" type="button" aria-label="Close the chat">&times;</button></div>' +
    '<div class="body" role="log" aria-live="polite" aria-atomic="false"></div>' +
    '<div class="foot"></div>' +
    '</section></div>';

  var wrap = root.querySelector(".wrap");
  var panel = root.querySelector(".panel");
  var launch = root.querySelector(".launch");
  var said = root.querySelector(".said");
  var body = root.querySelector(".body");
  var foot = root.querySelector(".foot");

  /**
   * Say something went wrong, wherever the panel currently is. A message
   * written into a node that has since been thrown away is a message nobody
   * gets - which is how a broken panel comes to look like an empty one.
   */
  function complain(message) {
    var where = foot.querySelector(".bad");
    if (where) {
      where.textContent = message;
      where.hidden = false;
    } else {
      say("system", "", message);
    }
  }

  function field(form, id) {
    var el = form.querySelector("#" + id);
    return el ? el.value.trim() : "";
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function say(who, from, text) {
    var el = document.createElement("div");
    el.className = "msg " + (who === "you" ? "you" : who === "system" ? "system" : "them");
    el.innerHTML =
      (who === "them" && from ? '<span class="from">' + esc(from) + "</span>" : "") + esc(text);
    body.appendChild(el);
    body.scrollTop = body.scrollHeight;
  }

  function ask(url, options) {
    return fetch(BASE + url, options).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error(j && j.error ? j.error : "Something went wrong.");
        return j;
      });
    });
  }

  // ── before they have said who they are ─────────────────────
  function drawForm(live, promise) {
    said.textContent = live ? "Somebody is here now" : "Leave a message";
    foot.innerHTML =
      '<form novalidate>' +
      '<p class="bad" hidden></p>' +
      (live
        ? ""
        : '<p class="note" style="margin:0 0 8px">Nobody is at the desk right now. Leave your question and we will come back to you ' +
          esc(promise || "as soon as we can") +
          ".</p>") +
      '<div class="field"><label for="zc-name">Your name</label>' +
      '<input id="zc-name" name="name" autocomplete="name" required></div>' +
      '<div class="field"><label for="zc-contact">Phone or email</label>' +
      '<input id="zc-contact" name="contact" autocomplete="tel" required></div>' +
      '<div class="field"><label for="zc-first">What can we help with?</label>' +
      '<textarea id="zc-first" name="message" required></textarea></div>' +
      '<div class="hp"><label for="zc-site">Leave this empty</label>' +
      '<input id="zc-site" name="website" tabindex="-1" autocomplete="off"></div>' +
      '<button class="go" type="submit">Start the chat</button>' +
      '<p class="note">' + esc(CONSENT) + " We do not use cookies here.</p>" +
      "</form>";

    var form = foot.querySelector("form");
    var bad = foot.querySelector(".bad");
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var go = form.querySelector(".go");
      // By id, not form.name: a form has a name of its own, and which one
      // wins there is a corner of the spec no public widget should rest on.
      var name = field(form, "zc-name");
      var contact = field(form, "zc-contact");
      var first = field(form, "zc-first");
      if (!name || !contact || !first) {
        bad.textContent = "Please give us your name, a way to reach you, and your question.";
        bad.hidden = false;
        return;
      }
      go.disabled = true;
      go.textContent = "Starting…";
      ask("/api/widget/start", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name: name,
          contact: contact,
          message: first,
          consent: CONSENT,
          website: field(form, "zc-site"),
        }),
      })
        .then(function (r) {
          state.token = r.token;
          state.started = true;
          try {
            sessionStorage.setItem(KEY, r.token);
          } catch (err) {
            /* a browser with storage switched off still chats, just not twice. */
          }
          said.textContent = r.live
            ? r.answering
              ? "You are talking to " + r.answering
              : "Somebody is here now"
            : "We will come back to you";
          body.innerHTML = "";
          if (!r.live) {
            say("system", "", "Thank you. Nobody is at the desk right now, so we will come back to you " + (r.promise || "as soon as we can") + ".");
          }
          drawComposer();
          poll();
          start();
        })
        .catch(function (err) {
          // Whatever went wrong has to reach the visitor. The panel it
          // started in may already have been replaced by this point, so the
          // place to say it is looked up now rather than remembered.
          complain(err.message);
          go.disabled = false;
          go.textContent = "Start the chat";
        });
    });
    var firstField = foot.querySelector("#zc-name");
    if (state.open && firstField) firstField.focus();
  }

  // ── once they are chatting ─────────────────────────────────
  function drawComposer() {
    foot.innerHTML =
      '<form novalidate>' +
      '<p class="bad" hidden></p>' +
      '<div class="field"><label for="zc-say">Your message</label>' +
      '<textarea id="zc-say" name="body" required></textarea></div>' +
      '<button class="go" type="submit">Send</button>' +
      "</form>";
    var form = foot.querySelector("form");
    var bad = foot.querySelector(".bad");
    var box = form.querySelector("#zc-say");
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var text = box.value.trim();
      if (!text) return;
      var go = form.querySelector(".go");
      go.disabled = true;
      ask("/api/widget/message", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token: state.token, body: text }),
      })
        .then(function () {
          box.value = "";
          bad.hidden = true;
          poll();
        })
        .catch(function (err) {
          bad.textContent = err.message;
          bad.hidden = false;
        })
        .then(function () {
          go.disabled = false;
          box.focus();
        });
    });
    box.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        form.requestSubmit ? form.requestSubmit() : form.dispatchEvent(new Event("submit", { cancelable: true }));
      }
    });
    if (state.open) box.focus();
  }

  function poll() {
    if (!state.token) return Promise.resolve();
    return ask("/api/widget/poll?token=" + encodeURIComponent(state.token) + "&since=" + state.since, {})
      .then(function (r) {
        (r.messages || []).forEach(function (m) {
          if (m.seq > state.since) state.since = m.seq;
          if (m.body) say(m.who, m.from, m.body);
        });
      })
      .catch(function (err) {
        // A dropped reply comes back on the next look, so this is not shown
        // to the visitor - but it is said out loud, because a catch that
        // swallows everything is how a broken panel looks like an empty one.
        if (window.console) console.warn("Zion chat: could not read replies.", err);
      });
  }

  // Every few seconds while the panel is open, and once a minute when it is
  // not - enough to notice an answer, not enough to be a load on anybody.
  function start() {
    stop();
    state.timer = setInterval(poll, state.open ? 5000 : 60000);
  }
  function stop() {
    if (state.timer) clearInterval(state.timer);
    state.timer = null;
  }

  // ── opening and closing ────────────────────────────────────
  var opener = null;

  function open() {
    state.open = true;
    wrap.setAttribute("data-open", "yes");
    panel.setAttribute("data-open", "yes");
    opener = launch;
    if (state.started) {
      var t = foot.querySelector("textarea");
      if (t) t.focus();
      start();
    } else if (state.config) {
      drawForm(state.config.live, state.config.promise);
    } else {
      load();
    }
  }

  function close() {
    state.open = false;
    wrap.setAttribute("data-open", "no");
    panel.setAttribute("data-open", "no");
    if (state.started) start();
    else stop();
    if (opener) opener.focus();
  }

  launch.addEventListener("click", open);
  root.querySelector(".x").addEventListener("click", close);
  root.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && state.open) {
      e.stopPropagation();
      close();
    }
  });

  function load() {
    foot.innerHTML = '<p class="note">One moment…</p>';
    ask("/api/widget/config", {})
      .then(function (c) {
        state.config = c;
        if (!c.enabled) {
          host.remove();
          return;
        }
        if (c.greeting) say("them", "", c.greeting);
        drawForm(c.live, c.promise);
      })
      .catch(function () {
        foot.innerHTML =
          '<p class="note">The chat is not available just now. Please call the office.</p>';
      });
  }

  // ── on the page ────────────────────────────────────────────
  function mount() {
    document.body.appendChild(host);
    // A tab that was already chatting picks it up where it was left.
    var saved = null;
    try {
      saved = sessionStorage.getItem(KEY);
    } catch (err) {
      saved = null;
    }
    if (saved) {
      state.token = saved;
      state.started = true;
      drawComposer();
      poll().then(function () {
        if (state.since === 0) {
          // The session has expired; start again rather than pretend.
          state.token = null;
          state.started = false;
          try {
            sessionStorage.removeItem(KEY);
          } catch (err) {
            /* nothing to remove */
          }
          body.innerHTML = "";
          foot.innerHTML = "";
        } else {
          start();
        }
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount);
  } else {
    mount();
  }
})();
