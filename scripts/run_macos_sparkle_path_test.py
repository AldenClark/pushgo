#!/usr/bin/env python3
"""Task-owned actual Sparkle standard-UI journeys; no fake installer."""
import argparse, base64, hashlib, http.server, json, os, plistlib, subprocess, sys, threading, time, unicodedata
from pathlib import Path
r=None
bundle='io.ethan.pushgo.sparkle-path-test-20261026'
driver=None
def run(*args,check=True):
 p=subprocess.run([str(a) for a in args],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if r is not None:
  with (r/'commands.jsonl').open('a') as f: f.write(json.dumps({'argv':[str(a) for a in args],'exit':p.returncode,'output':p.stdout,'time':time.time()})+'\n')
 if check and p.returncode: raise RuntimeError(f'{args}: exit {p.returncode}: {p.stdout}')
 return p.stdout.strip()
def ui(*args): return run(driver,*args)
def version(app): return plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
def sha(app): return hashlib.sha256((app/'Contents/Info.plist').read_bytes()).hexdigest()
def tree_sha(app):
 manifest=[]
 for p in sorted(app.rglob('*')):
  if p.is_file() and not p.is_symlink(): manifest.append((str(p.relative_to(app)),hashlib.sha256(p.read_bytes()).hexdigest()))
 return hashlib.sha256(json.dumps(manifest,separators=(',',':')).encode()).hexdigest()
def wait(predicate,seconds=40):
 deadline=time.monotonic()+seconds
 while time.monotonic()<deadline:
  if predicate(): return
  time.sleep(.2)
 raise AssertionError('bounded state wait expired')
def pids(): return run('pgrep','-x','TestHost',check=False).splitlines()
def launch(app):
 run('open','-n',app,'--args','-AppleLanguages','(en)','-AppleLocale','en_US')
 wait(lambda: bool(pids()),10)
 ui('wait-text',bundle,'Actual test host version '+version(app),'15')
 return pids()[0]
def appcast_requests():
 log=r/'http.log'
 return sum('GET /appcast.xml' in line for line in log.read_text().splitlines()) if log.exists() else 0
def alive(pid): return subprocess.run(['kill','-0',pid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
def run_case(case):
 assert ui('count',bundle)=='0','test host already running'
 name={'ascii-normal':'ASCII normal','ascii-quit':'ASCII quit','nfc-quit':unicodedata.normalize('NFC','Café 更新'),'nfd-quit':unicodedata.normalize('NFD','Café 更新')}[case]
 root=r/'runtime'/case/name; root.mkdir(parents=True,exist_ok=False); app=root/'PathTest.app'
 run('ditto',r/'test-inputs/1.0/PathTest.app',app)
 receipt={'case':case,'requested_parent':name,'codepoints':[f'U+{ord(c):04X}' for c in name],'filesystem_parent_utf8_hex':os.fsencode(os.listdir(root.parent)[0]).hex(),'old_info_sha256':sha(app),'old_bundle_sha256':tree_sha(app),'status':'RUNNING','started':time.time()}
 out=r/(case+'.json')
 def save(): out.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
 save()
 try:
  receipt['appcast_requests_before']=appcast_requests(); old=launch(app); receipt['old_pid']=old; receipt['old_identity']=json.loads(ui('identity',bundle,str(app)))
  ui('press-title',bundle,'10','Check for Updates')
  # Cancel one real update offer, retain old bytes/process, then do a fresh check.
  ui('press-title',bundle,'20','Skip This Version','Remind Me Later')
  assert alive(old) and version(app)=='1.0' and sha(app)==receipt['old_info_sha256']
  assert tree_sha(app)==receipt['old_bundle_sha256']; receipt['cancel_preserved_old']=True; receipt['appcast_requests_after_cancel']=appcast_requests(); assert receipt['appcast_requests_after_cancel']>receipt['appcast_requests_before']
  if case.endswith('normal'):
   ui('press-title',bundle,'10','Check for Updates')
   ui('press-title',bundle,'20','Install Update')
   receipt['appcast_requests_after_repeat']=appcast_requests(); assert receipt['appcast_requests_after_repeat']>receipt['appcast_requests_after_cancel']
   receipt['new_pid']=int(ui('wait-installed-relaunch',bundle,str(app),'2.0',old,'60'))
  else:
   ui('press-title',bundle,'10','Stage Update on Quit')
   wait(lambda: any(bundle in line and 'Autoupdate' in line for line in subprocess.check_output(['ps','-axo','command'],text=True).splitlines()),45)
   receipt['appcast_requests_after_repeat']=appcast_requests(); assert receipt['appcast_requests_after_repeat']>receipt['appcast_requests_after_cancel']
   ui('press-title',bundle,'10','Check for Updates')
   ui('press-title',bundle,'35','Install on Quit')
   states=[]
   for _ in range(20):
    assert alive(old) and version(app)=='1.0' and sha(app)==receipt['old_info_sha256'],'premature install while host running'
    states.append({'t':time.time(),'pid':old,'version':version(app),'info_sha256':sha(app)})
    time.sleep(.2)
   assert tree_sha(app)==receipt['old_bundle_sha256']; receipt['wait_observations']=states
   receipt['installer_actors_before_quit']=subprocess.check_output(['ps','-axo','pid,ppid,command'],text=True).splitlines()
   receipt['installer_actors_before_quit']=[x for x in receipt['installer_actors_before_quit'] if (bundle in x or str(r) in x) and ('Autoupdate' in x or 'Installer.xpc' in x or 'PathTest.app' in x)]
   ui('terminate',bundle)
   wait(lambda: not alive(old) and version(app)=='2.0',60)
   receipt['installed_after_quit']=True
   # Install on Quit honors quitting; explicitly open the updated app once.
   receipt['new_pid']=int(launch(app))
  assert version(app)=='2.0' and str(receipt['new_pid'])!=old
  ui('wait-text',bundle,'Actual test host version 2.0','15')
  receipt['new_identity']=json.loads(ui('identity',bundle,str(app))); receipt['new_info_sha256']=sha(app); receipt['new_info_matches_input']=sha(app)==sha(r/'test-inputs/2.0/PathTest.app'); assert receipt['new_info_matches_input']; receipt['new_bundle_sha256']=tree_sha(app); assert tree_sha(app)==tree_sha(r/'test-inputs/2.0/PathTest.app')
  receipt['status']='PASSED'
 except Exception as e:
  receipt['status']='FAILED'; receipt['error']=str(e)
  receipt['accessibility']=ui('dump',bundle); receipt['failure_identity']=run(driver,'identity',bundle,app,check=False); receipt['failure_version']=version(app); receipt['failure_bundle_sha256']=tree_sha(app)
  raise
 finally:
  receipt['finished']=time.time();save(); ui('terminate',bundle); wait(lambda: not pids() and ui('count',bundle)=='0',10)

def prepare(package, port):
 repo=Path(__file__).resolve().parents[1]
 run(repo/'scripts/require_unlocked_apple_ui_console.sh','macos_sparkle_path')
 run(sys.executable,repo/'scripts/quality_disk_preflight.py','--path',r,'--minimum-free-bytes',os.environ.get('QUALITY_MIN_FREE_BYTES','5368709120'))
 run('xcrun','swiftc','-framework','AppKit','-framework','ApplicationServices',repo/'scripts/macos_ui_driver.swift','-o',driver)
 assert ui('count',bundle)=='0','test host already running'
 framework=package/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
 run('xcrun','clang','-fobjc-arc','-framework','Cocoa','-framework','Sparkle','-F',framework.parent,'-Wl,-rpath,@executable_path/../Frameworks',repo/'scripts/fixtures/SparklePathTestHost.m','-o',r/'TestHost')
 run('openssl','genpkey','-algorithm','ED25519','-out',r/'test-only-private.pem')
 private=subprocess.check_output(['openssl','pkey','-in',str(r/'test-only-private.pem'),'-outform','DER'])[-32:]
 public=subprocess.check_output(['openssl','pkey','-in',str(r/'test-only-private.pem'),'-pubout','-outform','DER'])[-32:]
 (r/'test-only-edkey').write_bytes(base64.b64encode(private)+b'\n')
 for v in ['1.0','2.0']:
  app=r/'test-inputs'/v/'PathTest.app'; (app/'Contents/MacOS').mkdir(parents=True); (app/'Contents/Frameworks').mkdir()
  run('ditto',r/'TestHost',app/'Contents/MacOS/TestHost'); run('ditto',framework,app/'Contents/Frameworks/Sparkle.framework')
  info={'CFBundleExecutable':'TestHost','CFBundleIdentifier':bundle,'CFBundleName':'PathTest','CFBundlePackageType':'APPL','CFBundleVersion':v,'CFBundleShortVersionString':v,'LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication','SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml','SUPublicEDKey':base64.b64encode(public).decode(),'SUEnableInstallerLauncherService':True,'SUEnableAutomaticChecks':True,'SUScheduledCheckInterval':21600,'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':True,'SUHasLaunchedBefore':True}
  (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info)); run('codesign','--force','--sign','-',app)
 feed=r/'feed';feed.mkdir()
 run('ditto','-c','-k','--sequesterRsrc','--keepParent',r/'test-inputs/2.0/PathTest.app',feed/'PathTest-2.0.zip')
 run(package/'bin/generate_appcast','--ed-key-file',r/'test-only-edkey','--download-url-prefix',f'http://127.0.0.1:{port}/','--maximum-deltas','0','-o',feed/'appcast.xml',feed)

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--package-root',required=True,type=Path,help='Existing official Sparkle SPM artifact, unpacked; no downloads')
 parser.add_argument('--results-root',required=True,type=Path,help='New, task-owned output directory; retained for evidence')
 parser.add_argument('--port',type=int,default=48786)
 parser.add_argument('--reuse-inputs',type=Path,default=os.environ.get('MACOS_SPARKLE_PATH_REUSE_INPUTS'),help='Reuse retained signed task inputs and compiled host/driver; never copies private key files')
 parser.add_argument('--cases',nargs='+',choices=['ascii-normal','ascii-quit','nfc-quit','nfd-quit'],default=os.environ.get('MACOS_SPARKLE_PATH_CASES','ascii-normal ascii-quit nfc-quit nfd-quit').split())
 args=parser.parse_args(); r=args.results_root.resolve(); r.mkdir(parents=True,exist_ok=False); driver=r/'macos-ui-driver'
 server=None
 try:
  if args.reuse_inputs:
   source=Path(args.reuse_inputs).resolve()
   for item in ['test-inputs','feed','TestHost']: run('ditto',source/item,r/item)
   repo=Path(__file__).resolve().parents[1]
   run('xcrun','swiftc','-framework','AppKit','-framework','ApplicationServices',repo/'scripts/macos_ui_driver.swift','-o',driver)
   info=plistlib.loads((r/'test-inputs/1.0/PathTest.app/Contents/Info.plist').read_bytes())
   assert info['SUFeedURL']==f'http://127.0.0.1:{args.port}/appcast.xml'
   assert info['CFBundleIdentifier']==bundle
   (r/'reused-inputs.json').write_text(json.dumps({'source':str(source),'host_sha256':hashlib.sha256((r/'TestHost').read_bytes()).hexdigest(),'old_bundle':tree_sha(r/'test-inputs/1.0/PathTest.app'),'new_bundle':tree_sha(r/'test-inputs/2.0/PathTest.app')},indent=2)+'\n')
  else: prepare(args.package_root.resolve(),args.port)
  class Handler(http.server.SimpleHTTPRequestHandler):
   def __init__(self,*a,**kw): super().__init__(*a,directory=str(r/'feed'),**kw)
   def log_message(self,format,*args):
    with (r/'http.log').open('a') as f: f.write((format % args)+'\n')
  server=http.server.ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
  threading.Thread(target=server.serve_forever,daemon=True).start()
  for case in args.cases: run_case(case)
 finally:
  if server: server.shutdown();server.server_close()
  for key in ['test-only-private.pem','test-only-edkey']:
   (r/key).unlink(missing_ok=True)
