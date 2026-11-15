import json,os,sys,subprocess
from pathlib import Path
read=lambda:json.loads(sys.stdin.readline())
def send(v): print(json.dumps(v),flush=True)
def reply(r,v): send({'jsonrpc':'2.0','id':r['id'],'result':v})
root=Path.cwd();profile=Path(os.environ['GEMINI_HOME']); original=root/'original'
assert profile!=original and profile.is_relative_to(root)
assert Path(__file__).resolve().is_relative_to(profile/'runtime')
assert Path(os.environ['ANTIGRAVITY_HARNESS_PATH']).parent==Path(__file__).resolve().parent
assert os.environ['AGY_ACP_FORCE_FILE_STORAGE']=='1'
assert Path(os.environ['TMPDIR']).is_relative_to(profile/'runtime')
# Model an extracted runtime tree so completion must wait for real cleanup.
for index in range(32):
 extracted=Path(os.environ['TMPDIR'])/str(index);extracted.mkdir()
 (extracted/'runtime-part').write_bytes(b'fixture extraction')
assert os.environ['GEMINI_API_KEY']=='synthetic-owned-account-key'
for key in ['GOOGLE_API_KEY','GOOGLE_APPLICATION_CREDENTIALS','GOOGLE_CLOUD_PROJECT','AGY_ACP_ENABLE_OAUTH','AGY_LLM_GATEWAY_URL']:
 assert key not in os.environ
assert json.loads((profile/'antigravity-acp/settings.json').read_text())=={'auth':{'type':'gemini-api-key'}}
assert not (profile/'antigravity-acp/acp_token.json').exists()
(root/'pid').write_text(str(os.getpid()))
print('Antigravity diagnostic startup',flush=True)
r=read();assert r['method']=='initialize'
reply(r,{'protocolVersion':1,'agentCapabilities':{'loadSession':True,'sessionCapabilities':{'resume':{}},'promptCapabilities':{'image':True}},'authMethods':[{'id':'oauth-personal'},{'id':'gemini-api-key'}]})
r=read();assert r['method']=='authenticate' and r['params']=={'methodId':'gemini-api-key'}
if MODE=='auth-stdout':
 print('Open the following link to authenticate the ACP server: https://accounts.google.com/?secret-must-not-leak',flush=True);sys.stdin.readline();sys.exit(0)
if MODE=='auth-stderr':
 subprocess.run(['/bin/sh',str(profile/'browser-suppressed.sh'),'https://accounts.google.com/?secret-must-not-leak']);sys.stdin.readline();sys.exit(0)
reply(r,{'secret':'secret-must-not-leak'})
r=read();assert r['method']==('session/resume' if MODE.startswith('resume') else 'session/new')
if MODE.startswith('resume'):
 assert r['params']['sessionId']==ID
 assert (profile/'antigravity-acp/conversations'/f'{ID}.db').read_bytes()==b'native history'
 assert (profile/'antigravity-acp/brain'/ID/'artifact.txt').read_text()=='preserve artifact'
 send({'method':'session/update','params':{'sessionId':ID,'update':{'sessionUpdate':'agent_message_chunk','content':{'text':'OLD REPLAY'}}}})
 if MODE=='resume-failed':send({'id':r['id'],'error':{'code':-32602,'message':'secret-must-not-leak'}});sys.stdin.readline();sys.exit(0)
reply(r,{'sessionId':ID,'configOptions':[{'id':'model','category':'model','currentValue':'old','options':[{'value':'chosen'}]},{'id':'mode','category':'mode','currentValue':'yolo','options':[{'value':'default'},{'value':'yolo'}]}]})
r=read();assert r['method']=='session/set_config_option' and r['params']['configId']=='model' and r['params']['value']=='chosen'
reply(r,{'configOptions':[{'id':'model','currentValue':'chosen'}]})
r=read();assert r['method']=='session/set_config_option' and r['params']['configId']=='mode' and r['params']['value']=='default'
reply(r,{'configOptions':[{'id':'mode','currentValue':'default'}]})
prompt=read();assert prompt['method']=='session/prompt' and prompt['params']['prompt']==[{'type':'text','text':'fixture prompt'}]
(root/'ready').write_text('ready')
if MODE=='stop':
 r=read();assert r['method']=='session/cancel';reply(prompt,{'stopReason':'cancelled'});sys.stdin.readline();sys.exit(0)
send({'id':'approval','method':'session/request_permission','params':{'sessionId':ID,'toolCall':{'toolCallId':'write-tool','title':'Write file'},'options':[{'optionId':'always','kind':'allow_always'},{'optionId':'once','kind':'allow_once'},{'optionId':'no','kind':'reject_once'}]}})
r=read();assert r['result']['outcome']=={'outcome':'selected','optionId':'once'}
send({'id':'question','method':'session/request_permission','params':{'sessionId':ID,'toolCall':{'toolCallId':'interaction_choose','title':'Choose'},'options':[{'optionId':'one','name':'First','kind':'allow_once'},{'optionId':'two','name':'Second','kind':'allow_once'}]}})
r=read();assert r['result']['outcome']=={'outcome':'selected','optionId':'one'}
send({'id':'file','method':'fs/write_text_file','params':{'sessionId':ID,'path':str(root/'output.txt'),'content':'approved output'}})
assert not (root/'output.txt').exists()
r=read();assert r['id']=='file' and r['result']=={}
send({'id':'read','method':'fs/read_text_file','params':{'sessionId':ID,'path':str(root/'output.txt')}})
r=read();assert r['result']['content']=='approved output'
send({'method':'session/update','params':{'sessionId':ID,'update':{'sessionUpdate':'agent_message_chunk','content':{'text':'NEW ANSWER'}}}})
reply(prompt,{'stopReason':'end_turn'})
sys.stdin.readline()
