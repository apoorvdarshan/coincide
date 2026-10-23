"""Controlled stream-json peer: native tool-result fields, no provider calls."""
import json
import sys

def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

for line in sys.stdin:
    frame = json.loads(line)
    if frame.get('type') == 'control_request':
        response = {'models': [{'value': 'fixture-model', 'displayName': 'Fixture'}]} if frame['request']['subtype'] == 'initialize' else {}
        emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': response}})
    elif frame.get('type') == 'user':
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'owned-native-results'})
        cases = [
            ('failed', True, '<tool_use_error>Exact failure</tool_use_error>'),
            ('completed', False, 'Quoted <tool_use_error>example</tool_use_error> remains literal'),
            ('unknown', None, 'An arbitrary returned payload'),
            ('declined', True, 'Declined by the user in Coincide.'),
        ]
        for ident, flag, text in cases:
            emit({'type': 'assistant', 'session_id': 'owned-native-results', 'message': {'id': 'call-' + ident, 'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': ident, 'name': 'Bash', 'input': {'command': 'controlled display only'}}]}})
            block = {'type': 'tool_result', 'tool_use_id': ident, 'content': text}
            if flag is not None:
                block['is_error'] = flag
            emit({'type': 'user', 'session_id': 'owned-native-results', 'message': {'role': 'user', 'content': [block]}})
        emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': 'owned-native-results'})
