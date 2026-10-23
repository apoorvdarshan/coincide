"""Private no-provider Claude stream-json skill wire acceptance peer."""
import json
import os
import sys
import uuid

root = sys.argv[1]
session = str(uuid.uuid4())

def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

for line in sys.stdin:
    frame = json.loads(line)
    with open(os.path.join(root, 'skills-wire.jsonl'), 'a', encoding='utf-8') as target:
        target.write(json.dumps(frame, ensure_ascii=False) + '\n')
    if frame['type'] == 'control_request':
        subtype = frame['request']['subtype']
        assert subtype in ('initialize', 'set_permission_mode', 'set_model', 'interrupt')
        if subtype == 'initialize':
            emit({'type': 'system', 'subtype': 'init', 'session_id': session, 'parent_tool_use_id': None})
        emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'],
            'response': {'commands': [], 'models': []} if subtype == 'initialize' else {}}})
    elif frame['type'] == 'user':
        assert frame.get('parent_tool_use_id') is None
        content = frame['message']['content']
        assert isinstance(content, list) and content[-1]['type'] == 'text' and content[-1]['text'].startswith('/review')
        assert all('PRIVATE-BODY-MUST-NOT-BE-COPIED' not in str(block) for block in content)
        emit({'type': 'user', 'uuid': frame['uuid'], 'session_id': session, 'parent_tool_use_id': None,
            'message': frame['message']})
        emit({'type': 'assistant', 'uuid': str(uuid.uuid4()), 'session_id': session, 'parent_tool_use_id': None,
            'message': {'id': 'api-' + str(uuid.uuid4()), 'content': [{'type': 'text', 'text': 'Offline skill completed'}]}})
        emit({'type': 'result', 'session_id': session, 'parent_tool_use_id': None, 'is_error': False, 'result': 'Offline skill completed'})
    else:
        raise AssertionError('Unexpected frame')
