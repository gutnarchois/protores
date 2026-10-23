#!/usr/bin/env python3
"""End-to-end test. Run against a disposable database/server only."""
import concurrent.futures
import datetime
import json
import os
import urllib.request
import urllib.error

base = os.environ.get('TEST_API_BASE', 'http://127.0.0.1:8092/api/v1')
password = os.environ['TEST_ADMIN_PASSWORD']
def call(path, method='GET', data=None, token=None, expected=200):
    req = urllib.request.Request(base + path, method=method, data=json.dumps(data).encode() if data is not None else None,
        headers={'Content-Type': 'application/json', **({'Authorization': 'Bearer '+token} if token else {})})
    try:
        with urllib.request.urlopen(req,timeout=20) as response:
            code, body = response.status, json.load(response)
    except urllib.error.HTTPError as e:
        code, body = e.code, json.load(e)
    assert code == expected, (path, code, body)
    return body
admin = call('/auth/login', 'POST', {'username':'admin','password':password})['token']
call('/admin/users','POST',{'name':'Docente A','username':'docente-a','role':'teacher','password':password},admin)
call('/admin/users','POST',{'name':'Docente B','username':'docente-b','role':'teacher','password':password},admin)
call('/admin/users','POST',{'name':'Estudiante','username':'estudiante','role':'student','password':password},admin)
a=call('/auth/login','POST',{'username':'docente-a','password':password})
b=call('/auth/login','POST',{'username':'docente-b','password':password})
s=call('/auth/login','POST',{'username':'estudiante','password':password})['token']
g1=call('/admin/groups','POST',{'name':'6-1','teacher_id':a['user']['id']},admin)['id']
g2=call('/admin/groups','POST',{'name':'6-2','teacher_id':b['user']['id']},admin)['id']
date=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=5)).date().isoformat()
d=call('/admin/service-days','POST',{'date':date,'start':'09:00','minutes':10,'group_ids':[g1,g2]},admin)
cmd={'date':date,'version':1}
call('/admin/service-days','POST',{'date':date,'start':'09:00','minutes':10,'group_ids':[g1]},admin,409)
d=call(f"/admin/service-days/{d['id']}/start",'POST',cmd,admin)
cmd['version']=d['version']
call('/turns/1/finish','POST',cmd,s,403)
call('/admin/users',token=s,expected=403)
call('/admin/audit',token=a['token'],expected=403)
call('/turns/1/finish','POST',cmd,b['token'],403)
public=call('/status',token=s)
assert public['day']['turns'][0]['teacher_id']==0
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(lambda _:call('/turns/1/finish','POST',cmd,a['token']),range(8)))
d=call('/status',token=s)['day']
assert d['version']==3 and d['turns'][1]['status']=='active'
cmd['version']=3
d=call(f"/admin/service-days/{d['id']}/pause",'POST',cmd,admin)
cmd['version']=d['version']
call('/turns/2/finish','POST',cmd,b['token'],409)
d=call(f"/admin/service-days/{d['id']}/resume",'POST',cmd,admin)
cmd['version']=d['version']
d=call('/turns/2/finish','POST',cmd,b['token'])
assert d['status']=='finished'
call('/auth/logout','POST',{},s)
call('/status',token=s,expected=401)
print('PASS: login, roles, scheduling, conflicts, concurrent finish, pause/resume, complete day, logout')
