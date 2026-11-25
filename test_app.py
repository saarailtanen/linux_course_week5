import json

import pytest
import requests

import app as app_module
import db


class FakeOllamaResponse:
    def __init__(self, lines):
        self._lines = lines

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        pass

    def iter_lines(self):
        yield from self._lines


@pytest.fixture
def client(monkeypatch):
    monkeypatch.delenv('DB_NAME', raising=False)
    db._memory.clear()
    app_module.app.config['TESTING'] = True
    return app_module.app.test_client()


def parse_ndjson(body):
    return [json.loads(line) for line in body.splitlines() if line.strip()]


def test_index_shows_chat_ui(client):
    resp = client.get('/')
    assert resp.status_code == 200
    assert b'chat-form' in resp.data


def test_index_uses_forwarded_prefix(client):
    # Nginx sends the sub-path in X-Forwarded-Prefix
    resp = client.get('/', headers={'X-Forwarded-Prefix': '/viikko5'})
    assert b'/viikko5/static/style.css' in resp.data
    assert b'/viikko5/static/app.js' in resp.data


def test_index_without_prefix_works_locally(client):
    resp = client.get('/')
    assert b'/static/style.css' in resp.data
    assert b'/viikko5/' not in resp.data


def test_health_returns_deployed_revision(client, monkeypatch, tmp_path):
    revision = tmp_path / 'REVISION'
    revision.write_text('abc123', encoding='utf-8')
    monkeypatch.setattr(app_module, 'REVISION_FILE', revision)
    resp = client.get('/health')
    assert resp.status_code == 200
    assert resp.get_data(as_text=True).strip() == 'abc123'


def test_health_without_revision_file(client, monkeypatch, tmp_path):
    monkeypatch.setattr(app_module, 'REVISION_FILE', tmp_path / 'missing')
    assert client.get('/health').get_data(as_text=True).strip() == 'local'


def test_chat_rejects_missing_message(client):
    resp = client.post('/api/chat', json={'session_id': 'abcdef1234'})
    assert resp.status_code == 400


def test_chat_rejects_bad_session(client):
    resp = client.post('/api/chat', json={'session_id': '../etc', 'message': 'hello'})
    assert resp.status_code == 400


def test_chat_rejects_too_long_message(client):
    long_message = 'x' * (app_module.MAX_MESSAGE_LEN + 1)
    resp = client.post('/api/chat', json={'session_id': 'abcdef1234', 'message': long_message})
    assert resp.status_code == 400


def test_chat_streams_reply_and_saves_history(client, monkeypatch):
    lines = [
        json.dumps({'message': {'content': 'Hi'}, 'done': False}).encode(),
        json.dumps({'message': {'content': '!'}, 'done': True}).encode(),
    ]
    captured = {}

    def fake_post(url, **kwargs):
        captured['url'] = url
        captured.update(kwargs)
        return FakeOllamaResponse(lines)

    monkeypatch.setattr(app_module.requests, 'post', fake_post)

    resp = client.post('/api/chat', json={'session_id': 'test-session-1', 'message': 'Hello'})
    events = parse_ndjson(resp.get_data(as_text=True))

    assert resp.status_code == 200
    assert ''.join(e.get('token', '') for e in events) == 'Hi!'
    assert events[-1] == {'done': True}
    assert captured['url'].endswith('/api/chat')
    assert captured['json']['messages'][0]['role'] == 'system'
    assert captured['json']['messages'][-1] == {'role': 'user', 'content': 'Hello'}
    assert db.get_history('test-session-1') == [
        {'role': 'user', 'content': 'Hello'},
        {'role': 'assistant', 'content': 'Hi!'},
    ]


def test_chat_sends_previous_messages_as_context(client, monkeypatch):
    db.save_message('test-session-2', 'user', 'My name is Saara')
    db.save_message('test-session-2', 'assistant', 'Hello Saara!')
    captured = {}

    def fake_post(url, **kwargs):
        captured.update(kwargs)
        return FakeOllamaResponse([json.dumps({'message': {'content': 'Saara'}, 'done': True})])

    monkeypatch.setattr(app_module.requests, 'post', fake_post)
    resp = client.post('/api/chat', json={'session_id': 'test-session-2', 'message': 'My name?'})
    resp.get_data()

    roles = [m['role'] for m in captured['json']['messages']]
    assert roles == ['system', 'user', 'assistant', 'user']


def test_chat_handles_ollama_down(client, monkeypatch):
    def fake_post(url, **kwargs):
        raise requests.ConnectionError('connection refused')

    monkeypatch.setattr(app_module.requests, 'post', fake_post)

    resp = client.post('/api/chat', json={'session_id': 'test-session-3', 'message': 'Hello'})
    events = parse_ndjson(resp.get_data(as_text=True))

    assert 'error' in events[-1]
    assert db.get_history('test-session-3') == [{'role': 'user', 'content': 'Hello'}]


def test_chat_database_error_returns_json(client, monkeypatch):
    def broken_save(*args, **kwargs):
        raise db.DatabaseError(1290, 'The MariaDB server is running with the --read-only option')

    monkeypatch.setattr(db, 'save_message', broken_save)

    resp = client.post('/api/chat', json={'session_id': 'test-session-5', 'message': 'Hello'})

    assert resp.status_code == 503
    assert 'Database error' in resp.get_json()['error']


def test_history_endpoint(client):
    db.save_message('test-session-4', 'user', 'Hello')
    resp = client.get('/api/history/test-session-4')
    assert resp.status_code == 200
    assert resp.get_json() == [{'role': 'user', 'content': 'Hello'}]


def test_sessions_are_separate(client):
    db.save_message('session-aaaa-1', 'user', 'first')
    db.save_message('session-bbbb-2', 'user', 'second')
    first = client.get('/api/history/session-aaaa-1').get_json()
    second = client.get('/api/history/session-bbbb-2').get_json()
    assert first == [{'role': 'user', 'content': 'first'}]
    assert second == [{'role': 'user', 'content': 'second'}]

def test_docs_page(client):
    resp = client.get('/docs')
    assert resp.status_code == 200
    assert b'Request path' in resp.data

def test_deliberate_failure_demo():
    assert 1 + 1 == 3