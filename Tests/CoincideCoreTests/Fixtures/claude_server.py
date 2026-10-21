"""Offline peer for the public Claude stream-json control envelopes."""
import json
import sys

scenario = sys.argv[1]
permission = None
turn = 0

def emit(value):
    data = (json.dumps(value, ensure_ascii=False) + '\n').encode()
    for chunk in (data[:3], data[3:]):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()

def control_response(ident, result=None):
    emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': ident, 'response': result or {}}})

def finish(text='Hello Claude', is_error=False):
    ident = 'message-' + str(turn)
    emit({'type': 'stream_event', 'event': {'type': 'message_start', 'message': {'id': ident}}})
    emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text[:4]}}})
    emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text[4:]}}})
    emit({'type': 'assistant', 'session_id': 'claude-session', 'message': {'id': ident, 'content': [{'type': 'text', 'text': text}]}})
    emit({'type': 'result', 'is_error': is_error, 'session_id': 'claude-session', 'result': text})

for line in sys.stdin:
    frame = json.loads(line)
    if frame['type'] == 'control_request':
        request = frame['request']
        subtype = request['subtype']
        ident = frame['request_id']
        if subtype == 'initialize':
            control_response(ident, {'models': [{'value': 'fixture-model', 'displayName': 'Fixture Model'}]})
        elif subtype == 'set_permission_mode':
            permission = request['mode']
            control_response(ident)
        elif subtype == 'set_model':
            assert 'model' in request
            control_response(ident)
        elif subtype == 'interrupt':
            control_response(ident)
            emit({'type': 'result', 'session_id': 'claude-session', 'is_error': True, 'result': 'Interrupted'})
        else:
            raise AssertionError(subtype)
    elif frame['type'] == 'user':
        turn += 1
        assert permission == 'default'
        assert frame['message']['role'] == 'user'
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'claude-session'})
        if scenario == 'interrupt':
            continue
        if scenario == 'error':
            emit({'type': 'result', 'is_error': True, 'errors': ['Fixture provider failed'], 'session_id': 'claude-session'})
        elif scenario == 'question':
            emit({'type': 'control_request', 'request_id': 'question-1', 'request': {'subtype': 'can_use_tool', 'tool_name': 'AskUserQuestion', 'input': {'questions': [{'question': 'Which option?', 'header': 'Choice', 'multiSelect': False, 'options': [{'label': 'A', 'description': 'First'}]}]}}})
        else:
            emit({'type': 'control_request', 'request_id': 'approval-1', 'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'input': {'command': 'echo test'}}})
            if scenario == 'cancel':
                emit({'type': 'control_cancel_request', 'request_id': 'approval-1'})
                finish()
    elif frame['type'] == 'control_response':
        response = frame['response']
        assert response['subtype'] == 'success'
        result = response['response']
        if response['request_id'] == 'question-1':
            assert result['updatedInput']['answers'] == {'Which option?': 'A'}
            finish('Answer received')
        elif result['behavior'] == 'allow':
            assert result['updatedInput'] == {'command': 'echo test'}
            finish()
        else:
            assert result['behavior'] == 'deny'
            finish('Denied')
