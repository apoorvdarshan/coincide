"""Offline peer for the public Claude stream-json control envelopes."""
import json
import os
import sys
import time

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
    if scenario == 'held-initialize':
        with open(os.path.join(sys.argv[2], 'wire.jsonl'), 'a', encoding='utf-8') as log:
            log.write(json.dumps(frame) + '\n')
    if frame['type'] == 'control_request':
        request = frame['request']
        subtype = request['subtype']
        ident = frame['request_id']
        if subtype == 'initialize':
            if scenario == 'held-initialize':
                with open(os.path.join(sys.argv[2], 'ready'), 'w') as marker:
                    marker.write('ready')
                while not os.path.exists(os.path.join(sys.argv[2], 'release')):
                    time.sleep(.005)
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
        if scenario == 'identity':
            # A child can report its native identity before the root does.
            emit({'type': 'system', 'subtype': 'init', 'session_id': 'child-session',
                  'parent_tool_use_id': 'root-agent-tool'})
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'claude-session'})
        if scenario == 'identity':
            emit({'type': 'result', 'session_id': 'child-session',
                  'parent_tool_use_id': 'root-agent-tool', 'result': 'Child result'})
            emit({'type': 'system', 'subtype': 'init', 'session_id': 'foreign-root'})
            emit({'type': 'assistant', 'session_id': 'foreign-root',
                  'message': {'id': 'foreign-message', 'content': [{'type': 'text', 'text': 'Foreign reply'}]}})
            emit({'type': 'result', 'session_id': 'foreign-root', 'result': 'Foreign result'})
            finish()
        elif scenario == 'interrupt':
            continue
        elif scenario == 'error':
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
