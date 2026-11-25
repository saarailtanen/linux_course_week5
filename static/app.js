(function () {
  var base = document.body.getAttribute('data-base') || '';
  var messages = document.getElementById('messages');
  var form = document.getElementById('chat-form');
  var input = document.getElementById('message-input');
  var button = document.getElementById('send-button');
  var statusEl = document.getElementById('status');
  var newline = String.fromCharCode(10);

  // crypto.randomUUID() only works over HTTPS and this site is served over plain HTTP,
  // so the session id is built from getRandomValues(), which also works on HTTP.
  function makeId() {
    var bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += ('0' + bytes[i].toString(16)).slice(-2);
    }
    return out;
  }

  function getSessionId() {
    var id = null;
    try {
      id = localStorage.getItem('chat_session_id');
    } catch (e) {
      id = null;
    }
    if (!id) {
      id = makeId();
      try {
        localStorage.setItem('chat_session_id', id);
      } catch (e) {
        // storage blocked: the conversation then lasts only until the page is closed
      }
    }
    return id;
  }

  var sessionId = getSessionId();

  function addBubble(role, text) {
    var div = document.createElement('div');
    div.className = 'bubble ' + role;
    div.textContent = text;
    messages.appendChild(div);
    messages.scrollTop = messages.scrollHeight;
    return div;
  }

  function loadHistory() {
    fetch(base + '/api/history/' + sessionId)
      .then(function (resp) { return resp.json(); })
      .then(function (items) {
        if (Array.isArray(items)) {
          items.forEach(function (m) { addBubble(m.role, m.content); });
        }
      })
      .catch(function () {
        statusEl.textContent = 'Could not load the earlier messages.';
      });
  }

  function handleLine(line, reply) {
    if (!line.trim()) {
      return;
    }
    var evt = JSON.parse(line);
    if (evt.token) {
      reply.textContent += evt.token;
      messages.scrollTop = messages.scrollHeight;
    } else if (evt.error) {
      reply.className = 'bubble error';
      reply.textContent = evt.error;
    }
  }

  async function send(text) {
    addBubble('user', text);
    var reply = addBubble('assistant', '');
    button.disabled = true;
    statusEl.textContent = 'The model is thinking...';
    try {
      var resp = await fetch(base + '/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: sessionId, message: text })
      });
      if (!resp.ok) {
        var err = await resp.json();
        reply.className = 'bubble error';
        reply.textContent = err.error || 'Something went wrong.';
        return;
      }
      var reader = resp.body.getReader();
      var decoder = new TextDecoder();
      var buffer = '';
      while (true) {
        var chunk = await reader.read();
        if (chunk.done) {
          break;
        }
        buffer += decoder.decode(chunk.value, { stream: true });
        var lines = buffer.split(newline);
        buffer = lines.pop();
        for (var i = 0; i < lines.length; i++) {
          handleLine(lines[i], reply);
        }
      }
    } catch (e) {
      reply.className = 'bubble error';
      reply.textContent = 'Network error. Try again.';
    } finally {
      button.disabled = false;
      statusEl.textContent = '';
      input.focus();
    }
  }

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var text = input.value.trim();
    if (!text || button.disabled) {
      return;
    }
    input.value = '';
    send(text);
  });

  loadHistory();
})();
