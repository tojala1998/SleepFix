/* DOM/bridge regression harness. No TV service is invoked by this test. */
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const code = fs.readFileSync(path.join(__dirname, '../app/app.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '../app/index.html'), 'utf8');

function harness(options = {}) {
  const elements = {}, calls = [], listeners = {}, timers = new Map();
  let serial = 0;
  const document = {hidden:false, activeElement:null, getElementById:id => elements[id], addEventListener:(key, fn) => {listeners[key] = fn;}};
  for (const match of html.matchAll(/<(\w+)([^>]*\bid="([^"]+)"[^>]*)>/g)) {
    const id = match[3];
    elements[id] = {
      id, tagName:match[1].toUpperCase(), textContent:'', className:'', hidden: /\bhidden\b/.test(match[2]), disabled:/\bdisabled\b/.test(match[2]), attrs:{}, nav:/\bdata-nav\b/.test(match[2]),
      setAttribute(k,v) { this.attrs[k] = v; },
      focus() { document.activeElement = this; },
      click() { if (!this.disabled && this.onclick) this.onclick(); },
      getBoundingClientRect() { const i = Object.keys(elements).indexOf(id); return {top:i*80,bottom:i*80+60,left:0,right:300}; }
    };
    Object.defineProperty(elements[id], 'offsetParent', {get() { return ['confirm-button','cancel-button'].includes(id) && elements['confirm-overlay'].hidden ? null : {}; }});
  }
  document.querySelectorAll = () => Object.values(elements).filter(e => e.nav);
  elements['confirm-overlay'].querySelectorAll = () => [elements['cancel-button'], elements['confirm-button']];
  const window = {
    location:{search:options.preview ? '?preview=1' : ''},
    setTimeout(fn,ms) { const id = ++serial; timers.set(id,{fn,ms}); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval(fn,ms) { return 10000; },
    close() { window.closed = true; }
  };
  if (!options.noBridge) {
    window.PalmServiceBridge = function () {
      this.call = (uri,args) => {
        const parsed = JSON.parse(args);
        calls.push({uri,args:parsed,bridge:this});
        if (options.throwAction && parsed.command.endsWith(options.throwAction)) throw new Error('Reply channel closed');
      };
      this.cancel = () => {this.cancelled = true;};
    };
  }
  const context = vm.createContext({window,document,JSON,Object,String,Infinity,console});
  vm.runInContext(code, context);
  const status = overrides => Object.assign({returnValue:true,root:true,supported:true,running:true,bootEnabled:true,bootHookValid:true,operationInProgress:false,canStart:true,canStop:true,serviceState:'active/running',pid:6520,overlay:'ours',legacyHook:false,message:''}, overrides);
  const respond = (index, value) => calls[index].bridge.onservicecallback(JSON.stringify(value));
  const respondStatus = (index, overrides) => respond(index,{returnValue:true,stdoutString:JSON.stringify(status(overrides))});
  const fireTimers = ms => { for (const [id,item] of Array.from(timers)) if (item.ms === ms) {timers.delete(id);item.fn();} };
  return {elements,calls,window,listeners,timers,respond,respondStatus,fireTimers,status};
}

let checks = 0;
function check(name, body) { body(); console.log('PASS',name); checks += 1; }

check('launch only reads status and uses fixed HBC command', () => {
  const h = harness();
  assert.equal(h.calls.length,1);
  assert.equal(h.calls[0].uri,'luna://org.webosbrew.hbchannel.service/exec');
  assert.equal(h.calls[0].args.command,'/bin/sh /media/developer/apps/usr/palm/applications/io.github.tojala1998.sleepfix/bin/sleepfixctl.sh status-json');
  h.respondStatus(0);
  assert.equal(h.elements['status-badge-text'].textContent,'Running');
  assert.equal(h.elements['start-button'].disabled,false);
});
check('already running Start can adopt without timer confirmation', () => {
  const h = harness(); h.respondStatus(0,{legacyHook:true});
  h.elements['start-button'].click();
  assert.equal(h.elements['confirm-overlay'].hidden,true);
  assert(h.calls[1].args.command.endsWith('start --timers-off'));
  assert.equal(h.elements['stop-button'].disabled,true);
});
check('Stop confirms, preserves boot preference, and reads actual result', () => {
  const h = harness(); h.respondStatus(0);
  h.elements['stop-button'].click();
  assert.equal(h.calls.length,1);
  assert.equal(h.elements['confirm-overlay'].hidden,false);
  h.elements['confirm-button'].click();
  assert(h.calls[1].args.command.endsWith('stop --timers-off'));
  h.respond(1,{returnValue:true,stdoutString:'Stopped'});
  assert(h.calls[2].args.command.endsWith('status-json'));
  h.respondStatus(2,{running:false,overlay:'not_ours_or_absent',canStop:false});
  assert.equal(h.elements['status-badge-text'].textContent,'Stopped');
  assert.equal(h.elements['fix-toggle'].attrs['aria-checked'],'false');
  assert.equal(h.elements['boot-toggle'].attrs['aria-checked'],'true');
  assert(h.elements['daemon-detail'].textContent.startsWith('Running'));
});
check('Cancel leaves TV unchanged', () => {
  const h = harness(); h.respondStatus(0);
  h.elements['stop-button'].click(); h.elements['cancel-button'].click();
  assert.equal(h.calls.length,1);
});
check('boot toggle is independent and needs no restart confirmation', () => {
  const h = harness(); h.respondStatus(0);
  h.elements['boot-toggle'].click();
  assert(h.calls[1].args.command.endsWith('boot-off'));
  assert.equal(h.elements['confirm-overlay'].hidden,true);
});
check('unsupported executable blocks applying but permits owned rollback', () => {
  const h = harness(); h.respondStatus(0,{supported:false,running:false,overlay:'ours',canStart:false});
  assert.equal(h.elements['start-button'].disabled,true);
  assert.equal(h.elements['stop-button'].disabled,false);
});
check('partial patched process without mount still permits Stop', () => {
  const h = harness(); h.respondStatus(0,{running:false,overlay:'not_ours_or_absent',canStop:true});
  assert.equal(h.elements['stop-button'].disabled,false);
  assert.equal(h.elements['status-badge-text'].textContent,'Check service');
  assert(h.elements['status-description'].textContent.includes('partly applied'));
});
check('controller root rejection displays its explanation', () => {
  const h = harness();
  h.respond(0,{returnValue:false,stdoutString:JSON.stringify({returnValue:false,root:false,errorText:'Root access is required.'}),stderrString:''});
  assert.equal(h.elements['status-title'].textContent,'Root access is needed');
  assert.equal(h.elements['root-detail'].textContent,'Root unavailable');
  assert.equal(h.elements.notice.textContent,'Root access is required.');
  assert.equal(h.elements['start-button'].disabled,true);
});
check('bad status becomes Unknown rather than Stopped', () => {
  const h = harness(); h.respond(0,{returnValue:true,stdoutString:'invalid'});
  assert.equal(h.elements['status-badge-text'].textContent,'Unknown');
  assert.equal(h.elements['start-button'].disabled,true);
});
check('timeout keeps mutation locked until verified operation completion', () => {
  const h = harness(); h.respondStatus(0);
  h.elements['start-button'].click();
  h.fireTimers(120000);
  assert.equal(h.elements['start-button'].disabled,true);
  assert.equal(h.elements['refresh-button'].disabled,false);
  assert.equal(h.calls[1].bridge.cancelled,undefined);
  h.respondStatus(2,{operationInProgress:true});
  assert.equal(h.elements['start-button'].disabled,true);
  h.elements['refresh-button'].click();
  h.respondStatus(3,{operationInProgress:false});
  assert.equal(h.elements['start-button'].disabled,false);
});
check('completed controller failure remains visible after status readback', () => {
  const h = harness(); h.respondStatus(0);
  h.elements['start-button'].click();
  h.respond(1,{returnValue:false,stderrString:'ERROR: foreign overlay'});
  h.respondStatus(2);
  assert(h.elements.notice.textContent.includes('foreign overlay'));
});
check('bridge exception after dispatch is uncertain until actual status returns', () => {
  const h = harness({throwAction:'start --timers-off'}); h.respondStatus(0);
  h.elements['start-button'].click();
  assert.equal(h.elements['status-badge-text'].textContent,'Checking');
  assert.equal(h.elements['start-button'].disabled,true);
  assert(h.calls[2].args.command.endsWith('status-json'));
  h.respondStatus(2,{operationInProgress:false});
  assert.equal(h.elements['status-badge-text'].textContent,'Running');
  assert.equal(h.elements['start-button'].disabled,false);
});
check('missing native bridge cannot pretend to be connected', () => {
  const h = harness({noBridge:true});
  assert.equal(h.elements['status-badge-text'].textContent,'Unknown');
  assert.equal(h.elements['fix-toggle'].disabled,true);
  assert.equal(h.calls.length,0);
});
check('explicit preview never calls native Luna service', () => {
  const h = harness({preview:true}); h.fireTimers(80);
  assert.equal(h.elements['preview-label'].hidden,false);
  assert.equal(h.elements['status-badge-text'].textContent,'Running');
  h.elements['boot-toggle'].click(); h.fireTimers(450); h.fireTimers(80);
  assert.equal(h.calls.length,0);
  assert.equal(h.elements['boot-toggle'].attrs['aria-checked'],'false');
});
check('remote Back cancels dialog without executing action', () => {
  const h = harness(); h.respondStatus(0);
  h.elements['stop-button'].click();
  h.listeners.keydown({keyCode:461,preventDefault(){}});
  assert.equal(h.elements['confirm-overlay'].hidden,true);
  assert.equal(h.calls.length,1);
});
console.log(checks + ' UI/bridge checks passed. No physical-TV test is claimed.');
