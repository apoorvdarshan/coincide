"""Asserts native multimodal payloads; no model, credentials or user data."""
import base64
import json
import sys

kind = sys.argv[1]

def emit(value):
    print(json.dumps(value), flush=True)

def check_image(mime, data):
    assert mime == 'image/png'
    assert base64.b64decode(data).startswith(b'\x89PNG\r\n\x1a\n')

for line in sys.stdin:
    frame = json.loads(line)
    if kind == 'codex':
        method, ident = frame.get('method'), frame.get('id')
        if method == 'initialize':
            emit({'id': ident, 'result': {}})
        elif method == 'thread/start':
            emit({'id': ident, 'result': {'thread': {'id': 'attachment-thread'}}})
        elif method == 'turn/start':
            content = frame['params']['input']
            assert len(content) == 2 and content[0]['type'] == 'text'
            assert 'Read this note' in content[0]['text'] and 'Attached file' in content[0]['text']
            assert content[1]['type'] == 'image'
            check_image('image/png', content[1]['url'].removeprefix('data:image/png;base64,'))
            emit({'id': ident, 'result': {'turn': {'id': 'attachment-turn'}}})
            emit({'method': 'item/completed', 'params': {'item': {'id': 'message', 'type': 'agentMessage', 'text': 'ATTACHMENT_FIXTURE_OK'}}})
            emit({'method': 'turn/completed', 'params': {'turn': {'id': 'attachment-turn', 'status': 'completed'}}})
    elif frame['type'] == 'control_request':
        emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': {}}})
    elif frame['type'] == 'user':
        content = frame['message']['content']
        assert len(content) == 2 and content[0]['type'] == 'image'
        check_image(content[0]['source']['media_type'], content[0]['source']['data'])
        assert content[0]['source']['type'] == 'base64'
        assert content[1]['type'] == 'text' and 'Read this note' in content[1]['text'] and 'Attached file' in content[1]['text']
        emit({'type': 'assistant', 'session_id': 'attachment-session', 'message': {'id': 'message', 'content': [{'type': 'text', 'text': 'ATTACHMENT_FIXTURE_OK'}]}})
        emit({'type': 'result', 'session_id': 'attachment-session', 'is_error': False})
