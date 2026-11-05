"""Check Git-selected source and optionally every reachable Git blob. Never prints secret values."""
from pathlib import Path
import argparse
import ipaddress
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(rb'(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)')
IP = re.compile(rb'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')
PERSONAL_PATH = re.compile(rb'(?:[A-Za-z]:[\\/]Users[\\/][^\s\\/"<>]+|/' + rb'Users/[^\s/"<>]+/(?:Documents|Desktop|Downloads|Library|Pictures|Music|Movies)/|/' + rb'home/[^\s/"<>]+/(?:Documents|Desktop|Downloads|\.ssh|\.config)/)')
NETWORKS = [ipaddress.ip_network((10 << 24, 8)), ipaddress.ip_network((172 << 24 | 16 << 16, 12)),
            ipaddress.ip_network((192 << 24 | 168 << 16, 16)), ipaddress.ip_network((100 << 24 | 64 << 16, 10)),
            ipaddress.ip_network((169 << 24 | 254 << 16, 16))]
FORBIDDEN_EXT = {'.hap','.hsp','.har','.so','.a','.o','.p12','.pfx','.jks','.keystore','.pem','.key','.cer','.crt','.csr','.log','.bak','.pyc','.db'}
FORBIDDEN_PART = {'.idea','.hvigor','oh_modules','node_modules','__pycache__','artifacts'}

def git(*args):
    return subprocess.check_output(['git','-C',str(ROOT),*args])

def objects(ids):
    ids=sorted(set(ids))
    if not ids:return {}
    process=subprocess.run(['git','-C',str(ROOT),'cat-file','--batch'],
                           input=('\n'.join(ids)+'\n').encode(),capture_output=True,check=True)
    data=process.stdout;offset=0;result={}
    for expected in ids:
        end=data.index(b'\n',offset);header=data[offset:end].split()
        if len(header)!=3:raise ValueError('Unreadable Git object')
        oid,kind,size=header;length=int(size);start=end+1
        result[expected]=(kind,data[start:start+length]);offset=start+length+1
    return result

def path_findings(name):
    p=Path(name)
    result=[]
    if p.suffix.lower() in FORBIDDEN_EXT or any(x in FORBIDDEN_PART for x in p.parts): result.append('generated/signing/runtime file')
    if name in {'build-profile.json5','local.properties','.npmrc','.ohpmrc'} or p.name.startswith('.env'): result.append('machine/secret configuration')
    if name.startswith(('entry/build/','dist/','.cache/')): result.append('build/cache output')
    return result

def inspect(data, name):
    problems=path_findings(name)
    views=[data]
    # Binary tools/configs can store UTF-16 literals; inspect them as text too.
    if b'\x00' in data[:8192]:
        for codec in ['utf-16-le','utf-16-be']:
            try: views.append(data.decode(codec,errors='ignore').encode('utf-8'))
            except UnicodeError: pass
    for body in views:
        if KEY.search(body): problems.append('credential/private-key shape')
        if not name.startswith('vendor/') and PERSONAL_PATH.search(body): problems.append('personal machine path')
        if not name.startswith('vendor/'):
            for match in IP.finditer(body):
                try: value=ipaddress.ip_address(match[0].decode())
                except ValueError: continue
                if any(value in net for net in NETWORKS):
                    problems.append('private/shared-network literal'); break
    return sorted(set(problems))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--git-history',action='store_true')
    args=parser.parse_args()
    names=git('ls-files','--cached','--others','--exclude-standard','-z').decode('utf-8').split('\0')
    failures=[]; checked=0
    for name in sorted(set(filter(None,names))):
        path=ROOT/name
        if path.is_symlink(): failures.append((name,['symbolic link'])); continue
        if not path.is_file(): failures.append((name,['missing selected file'])); continue
        findings=inspect(path.read_bytes(),name); checked+=1
        if findings: failures.append((name,findings))
    staged=[]
    for entry in git('ls-files','--stage','-z').split(b'\0'):
        if not entry:continue
        metadata,name=entry.split(b'\t',1)
        mode,oid,stage=metadata.split()
        staged.append((oid.decode(),name.decode('utf-8')))
        if stage!=b'0':failures.append((name.decode('utf-8'),['unresolved index stage']))
    staged_content=objects(oid for oid,name in staged)
    for (oid,name) in staged:
        kind,data=staged_content[oid]
        findings=inspect(data,name)
        if findings:failures.append(('index:'+name,findings))
    history_blobs=0
    if args.git_history:
        historical=[]
        for line in git('rev-list','--objects','--all').decode('utf-8').splitlines():
            fields=line.split(' ',1)
            if len(fields)!=2: continue
            oid,name=fields
            historical.append((oid,name))
        content=objects(oid for oid,name in historical)
        for oid,name in historical:
            kind,data=content[oid]
            if kind!=b'blob':continue
            findings=inspect(data,name); history_blobs+=1
            if findings: failures.append(('history:'+name,findings))
        for commit in git('rev-list','--all').decode().splitlines():
            for name in git('ls-tree','-r','--name-only','-z',commit).decode('utf-8').split('\0'):
                if name and path_findings(name): failures.append(('history-path:'+name,path_findings(name)))
    for name,reasons in failures: print(name+': '+', '.join(reasons))
    print(f'Publication scan: files={checked}, history_blobs={history_blobs}, findings={len(failures)}')
    print('Pattern checks complement review; screenshots and dependencies require separate inspection.')
    return bool(failures)

if __name__=='__main__': sys.exit(main())
