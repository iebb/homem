"""UI-test data served over HTTP, never bundled into the application."""
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse
import threading
import uuid

LOCK = threading.RLock()
COLLECTIONS = {}
DOCUMENTS = {}
MESSAGES = {}
COUNTS = {}
SCENARIO = ''


def reset(scenario=""):
    global SCENARIO
    with LOCK:
        SCENARIO = scenario
        COLLECTIONS.clear(); DOCUMENTS.clear(); MESSAGES.clear(); COUNTS.clear()
        COLLECTIONS['/bots'] = [dict(id=b, name=b, display_name=n, is_active=True, status='ready', current_user_permissions=['chat','manage']) for b,n in [('atlas','Atlas'),('mika','Mika'),('sage','Sage')]]
        for b in ['atlas','mika','sage']:
            base='/bots/'+b
            COLLECTIONS[base+'/sessions'] = []
            COLLECTIONS[base+'/memory'] = [{'id':'memory-1','memory':'Prefers thoughtful answers with concrete examples.'}]
            COLLECTIONS[base+'/schedule'] = [{'id':'morning','name':'Morning perspective','command':'Fixture task','pattern':'0 9 * * *','enabled':True}]
            COLLECTIONS[base+'/agents'] = [{'id':'native','name':'Memoh','type':'native','enabled':True}]
            DOCUMENTS[base+'/workspace-targets'] = {'targets':[{'target_id':'native','kind':'native','primary':True},{'target_id':'fixture-mac','kind':'remote','name':'Studio Mac','online':True,'status':'online'}]}
            DOCUMENTS[base+'/settings'] = {'language':'en'}
            DOCUMENTS[base+'/container'] = {'status':'running','runtime':'docker','id':'workspace-'+b}
            if scenario == 'resource-metrics':
                DOCUMENTS[base+'/container/metrics'] = {
                    'metrics': {'cpu': {'usage_nanocores': 500_000_000}, 'memory': {'usage_bytes': 268_435_456, 'limit_bytes': 1_073_741_824}, 'storage': {'used_bytes': 536_870_912}},
                    'resource_limits': {'applied': {'cpu_millicores': 2000, 'memory_bytes': 1_073_741_824, 'storage_bytes': 10_737_418_240}},
                }
            DOCUMENTS[base+'/token-usage'] = {'chat':[],'discuss':[],'schedule':[],'acp_agent':[]}
            DOCUMENTS[base+'/checks'] = {'state':'ok','issues':[]}
        COLLECTIONS['/bots/atlas/sessions'] = [dict(id=i,bot_id='atlas',title=t,type='chat',updated_at='2026-09-16T14:00:00Z') for i,t in [('welcome','A place for your next idea'),('research','A weekend in Kyoto')]]
        MESSAGES['welcome'] = [{'turn_id':'welcome','role':'assistant','messages':[{'id':1,'type':'text','content':'A conversation from the local test server.'}],'timestamp':'2026-09-16T14:00:00Z'}]
        if scenario == 'screenshots':
            COLLECTIONS['/bots/atlas/sessions'] = [
                dict(id=i,bot_id='atlas',title=t,type='chat',updated_at='2026-09-30T14:00:00Z')
                for i,t in [
                    ('welcome','A calmer way to plan the week'),
                    ('research','A weekend in Kyoto'),
                    ('writing','Shape a new product story'),
                ]
            ]
            MESSAGES['welcome'] = [
                {'turn_id':'plan-user','role':'user','text':'Help me make room for focused work, a team check-in, and a little time outdoors this week.','timestamp':'2026-09-30T13:58:00Z'},
                {'turn_id':'plan-answer','role':'assistant','messages':[{'id':1,'type':'text','content':'Here is a rhythm that leaves room to breathe:\n\n**Monday–Tuesday** · Protect two morning focus blocks for the work that needs your full attention.\n\n**Wednesday** · Hold the team check-in after lunch, when everyone has progress to share.\n\n**Thursday–Friday** · Keep one open afternoon for follow-ups, then step outside before the day ends.\n\nI can turn this into a checklist or help you adjust it around your calendar.'}],'timestamp':'2026-09-30T14:00:00Z'},
            ]
            MESSAGES['research'] = [
                {'turn_id':'kyoto-user','role':'user','text':'Plan a slow weekend in Kyoto with gardens, good coffee, and time to wander.','timestamp':'2026-09-30T12:00:00Z'},
                {'turn_id':'kyoto-answer','role':'assistant','messages':[{'id':1,'type':'text','content':'**Saturday** · Begin early on the Philosopher’s Path, pause for coffee in Higashiyama, and leave the afternoon open for small streets and galleries.\n\n**Sunday** · Visit a garden in the morning, linger over lunch, and save the last hour for a quiet walk by the Kamo River.\n\nThe plan is intentionally light, so each discovery has room to become the next stop.'}],'timestamp':'2026-09-30T12:02:00Z'},
            ]
            MESSAGES['writing'] = [
                {'turn_id':'story-user','role':'user','text':'Give our new workspace a simple, human introduction.','timestamp':'2026-09-30T10:00:00Z'},
                {'turn_id':'story-answer','role':'assistant','messages':[{'id':1,'type':'text','content':'**A place for your next idea.**\n\nBring your conversations, files, and tools together in one calm workspace. Move between tasks without losing the thread, and let your assistant help you make progress at your own pace.'}],'timestamp':'2026-09-30T10:01:00Z'},
            ]
            DOCUMENTS['/users/me'] = {'id':'ui-fixture-user','username':'alex','display_name':'Alex Morgan','role':'admin'}
        if scenario == 'tools':
            MESSAGES['welcome'] = [{'turn_id':'tools','role':'assistant','messages':[{'id':1,'type':'tool','name':'read_file','input':{'path':'/data/notes.txt'},'output':'Read notes.'},{'id':2,'type':'tool','name':'web_search','input':{'query':'weather'},'output':'Found results.'},{'id':3,'type':'tool','name':'update_schedule','input':{'name':'Morning'},'output':'Schedule updated.'},{'id':4,'type':'text','content':'Your schedule is up to date.'}]}]
        COLLECTIONS['/models'] = []
        COLLECTIONS['/providers'] = [{'id':'fixture-provider','name':'Example provider','client_type':'openai-responses'}]
        if scenario != 'screenshots':
            DOCUMENTS['/users/me'] = {'id':'ui-fixture-user','username':'fixture','display_name':'Fixture User','role':'admin'}


def account_key(authorization):
    return 'second' if authorization == 'Bearer homem-local-fixture-second-token' else 'first'


def message_key(account, session):
    return ('second|' if account == 'second' else '') + session


def response(path, method, body=None, authorization=''):
    parsed=urlparse(path); path=parsed.path; query=parse_qs(parsed.query); body=body or {}
    account=account_key(authorization)
    with LOCK:
        if path=='/ui/reset': reset(body.get('scenario','')); return {},200
        if path=='/ui/counts': return dict(COUNTS),200
        COUNTS[path]=COUNTS.get(path,0)+1
        COUNTS[method+' '+path]=COUNTS.get(method+' '+path,0)+1
        if path=='/api/v1/auth/email-code/send': return {'resend_after':60},200
        if path=='/api/v1/auth/email-code/verify':
            if body.get('code') != '123456': return {'message':'Invalid code'},400
            return {'mfa_required':True,'mfa_token':'fixture-mfa'},200
        if path=='/api/v1/auth/verify-mfa':
            if body.get('totp_code') != '654321': return {'message':'Invalid code'},400
            return {},200
        if path=='/api/v1/users/me': return {'user':{'id':'fixture-official','email':'person@example.com'}},200
        if path=='/api/v1/teams': return {'teams':[{'team':{'team_id':'one','name':'Personal workspace'}},{'team':{'team_id':'two','name':'Team workspace'}}]},200
        path=path.removeprefix('/ui-api')
        if path=='/auth/login':
            token='homem-local-fixture-second-token' if body.get('username')=='fixture-two' else 'homem-local-fixture-token'
            return {'access_token':token},200
        if account=='second' and path=='/users/me':
            return {'id':'ui-fixture-second','username':'fixture-two','display_name':'Second Fixture User','role':'admin'},200
        if account=='second' and path=='/bots/atlas/sessions':
            return {'items':[dict(id='welcome',bot_id='atlas',title='Second account conversation',type='chat',updated_at='2026-09-16T14:00:00Z')]},200
        if path.endswith('/messages'):
            return {'items':MESSAGES.get(message_key(account,query.get('session_id',[''])[0]),[])},200
        if path.endswith('/queue'): return {'steer':[],'follow_up':[],'steer_supported':True},200
        if path.endswith('/container/fs/list'):
            if account=='second': return {'entries':[{'name':'SECOND.md','path':'/data/SECOND.md','isDir':False,'size':100}]},200
            if SCENARIO == 'screenshots':
                return {'entries':[
                    {'name':'Weekly plan.md','path':'/data/Weekly plan.md','isDir':False,'size':1840},
                    {'name':'Kyoto ideas.md','path':'/data/Kyoto ideas.md','isDir':False,'size':2560},
                    {'name':'Product story.md','path':'/data/Product story.md','isDir':False,'size':980},
                    {'name':'Research notes.md','path':'/data/Research notes.md','isDir':False,'size':3120},
                    {'name':'Launch checklist.md','path':'/data/Launch checklist.md','isDir':False,'size':1450},
                    {'name':'Reading list.md','path':'/data/Reading list.md','isDir':False,'size':760},
                ]},200
            return {'entries':[{'name':'AGENTS.md','path':'/data/AGENTS.md','isDir':False,'size':100}]},200
        if path.endswith('/container/fs/read'):
            content='# A workspace of your own\n\nThis file comes from the local test fixture.\n'
            if SCENARIO == 'screenshots':
                content='# Weekly plan\n\n## Make room for what matters\n\n- [ ] Protect two morning focus blocks\n- [ ] Prepare Wednesday’s team check-in\n- [ ] Keep Friday afternoon open for follow-ups\n- [ ] Step outside before the day ends\n\nA little breathing room makes the week work better.\n'
            return {'content':content,'revision':'fixture'},200
        if method in ('PUT','PATCH'):
            if path in DOCUMENTS:
                DOCUMENTS[path].update(body)
                return DOCUMENTS[path],200
            parent,_,identifier=path.rpartition('/')
            record=next((x for x in COLLECTIONS.get(parent,[]) if x.get('id')==identifier),None)
            if record is not None:
                record.update(body)
                return record,200
            return {'message':'Fixture item not found'},404
        if '/sessions/' in path: return {'id':path.rsplit('/',1)[1],'type':'chat','settings':{}},200
        if method=='GET':
            if path in COLLECTIONS: return {'items':COLLECTIONS[path]},200
            if path in DOCUMENTS: return DOCUMENTS[path],200
            parent,_,identifier=path.rpartition('/')
            value=next((x for x in COLLECTIONS.get(parent,[]) if x.get('id')==identifier),None)
            if value: return value,200
            return {'items':[]},200
        if method=='POST' and path in COLLECTIONS:
            value={**body,'id':str(uuid.uuid4()),'updated_at':datetime.now(timezone.utc).isoformat()}
            if path.endswith('/memory'): value['memory']=body.get('message','')
            if path.endswith('/sessions'): value['bot_id']=path.split('/')[2]
            COLLECTIONS[path].append(value)
            return value,200
        parent,_,identifier=path.rpartition('/')
        if method=='DELETE':
            COLLECTIONS[parent]=[x for x in COLLECTIONS.get(parent,[]) if x.get('id')!=identifier]
            return {},200
        return body,200

reset()
