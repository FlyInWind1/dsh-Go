// 整页画布 (docs/design/roleplay-ui.md §3, roleplay-compat.md §6.3; the
// roadmap's level 2): the whole story in one web page, its DOM built the way
// SillyTavern builds it (#chat > .mes[mesid] > .mes_block > .mes_text), so a
// card's CSS that reaches across messages (#chat .mes …) takes, and ST's own
// colour variables (--SmartThemeQuoteColor …) carry the story's colours.
// Messages arrive as JSON through our script; the page itself is loaded once.
// Card scripts don't run yet: they come with the helper bridge. Component
// tags (<dsh-letter>…, roleplay-ui §5) are Web Components here, with parts
// and --dsh-* variables a card's CSS may restyle.

import 'dart:convert';
import 'dart:ui' show Color;

/// One message on the canvas.
final class TavernCanvasEntry {
  const TavernCanvasEntry({
    required this.mesid,
    required this.nodeId,
    required this.name,
    required this.html,
    this.isUser = false,
    this.isSystem = false,
  });

  /// Its place in the shown path, as ST numbers messages.
  final int mesid;
  final String nodeId;
  final String name;
  final String html;
  final bool isUser;
  final bool isSystem;

  Map<String, Object?> toJson() => {
    'mesid': mesid,
    'node': nodeId,
    'name': name,
    'html': html,
    'user': isUser,
    'system': isSystem,
  };
}

/// The words the canvas's components say, in the reader's language:
/// letterFrom and phoneFrom carry `{from}`, rollCheck `{skill}`.
final class TavernCanvasLabels {
  const TavernCanvasLabels({
    this.letter = 'A letter',
    this.letterFrom = 'A letter from {from}',
    this.taken = 'Got',
    this.clue = 'Clue',
    this.phone = 'A message',
    this.phoneFrom = 'Message from {from}',
    this.roll = 'Roll',
    this.rollCheck = 'Check: {skill}',
    this.success = 'Success',
    this.failure = 'Failure',
    this.game = "A mini-game goes here; it can't be played here yet",
  });

  final String letter, letterFrom, taken, clue, phone, phoneFrom, roll, rollCheck, success, failure, game;

  Map<String, String> toJson() => {
    'letter': letter,
    'letterFrom': letterFrom,
    'taken': taken,
    'clue': clue,
    'phone': phone,
    'phoneFrom': phoneFrom,
    'roll': roll,
    'rollCheck': rollCheck,
    'success': success,
    'failure': failure,
    'game': game,
  };
}

/// [entries] as our script's render() takes them.
String tavernCanvasJson(List<TavernCanvasEntry> entries) => jsonEncode([for (final e in entries) e.toJson()]);

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

final _tagOrText = RegExp(r'<[^<>]*>|[^<]+|<');

/// What is said, as ST marks it: the quote marks kept, inside a <q>.
final _said = RegExp('"[^"\\n]*"|\u201C[^\u201D\\n]*\u201D|\u00AB[^\u00BB\\n]*\u00BB|「[^」\\n]*」|『[^』\\n]*』|＂[^＂\\n]*＂');
final _strong = RegExp(r'\*\*(?!\s)([^*\n]+?)(?<!\s)\*\*');
final _em = RegExp(r'(?<![*\w])\*(?![\s*])([^*\n]+?)(?<!\s)\*(?![*\w])');
final _emUnderscore = RegExp(r'(?<![\w_])_(?![\s_])([^_\n]+?)(?<!\s)_(?![\w_])');
final _code = RegExp(r'`([^`\n]+)`');

/// Markdown's inline marks in [text], leaving HTML tags (and what their
/// attributes say) as written.
String _inline(String text) {
  final out = StringBuffer();
  for (final m in _tagOrText.allMatches(text)) {
    final piece = m[0]!;
    if (piece.startsWith('<') && piece.length > 1) {
      out.write(piece);
      continue;
    }
    // Code first: nothing inside it is formatted.
    var at = 0;
    for (final c in _code.allMatches(piece)) {
      out.write(_words(piece.substring(at, c.start)));
      out.write('<code>${_escape(c[1]!)}</code>');
      at = c.end;
    }
    out.write(_words(piece.substring(at)));
  }
  return out.toString();
}

String _words(String text) => text
    .replaceAllMapped(_strong, (m) => '<strong>${m[1]}</strong>')
    .replaceAllMapped(_em, (m) => '<em>${m[1]}</em>')
    .replaceAllMapped(_emUnderscore, (m) => '<em>${m[1]}</em>')
    .replaceAllMapped(_said, (m) => '<q>${m[0]}</q>');

final _fence = RegExp(r'^(`{3,}|~{3,})[ \t]*([\w-]*)[^\n]*\n([\s\S]*?)\n?^\1[ \t]*$', multiLine: true);
final _blockTag = RegExp(
  r'^<(div|p|style|script|table|details|section|article|center|ul|ol|blockquote|pre|h[1-6]|hr|img|svg|iframe|form|figure|dsh-[a-z-]+)\b',
  caseSensitive: false,
);
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');

/// A message's text as the canvas shows it: paragraphs with their line
/// breaks, Markdown's emphasis, what is said in <q>, ```html blocks and block
/// HTML as written, other code blocks escaped.
String tavernStoryHtml(String text) {
  final source = text.replaceAll('\r\n', '\n');
  final out = <String>[];
  void prose(String segment) {
    for (final block in segment.split(RegExp(r'\n[ \t]*\n'))) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;
      if (_blockTag.hasMatch(trimmed)) {
        out.add(trimmed);
      } else if (_heading.firstMatch(trimmed) case final h? when !trimmed.contains('\n')) {
        final level = h[1]!.length;
        out.add('<h$level>${_inline(h[2]!)}</h$level>');
      } else if (trimmed.split('\n').every((l) => l.trimLeft().startsWith('>'))) {
        final inner = [for (final l in trimmed.split('\n')) l.trimLeft().substring(1).trimLeft()].join('\n');
        out.add('<blockquote><p>${_inline(inner).replaceAll('\n', '<br>')}</p></blockquote>');
      } else {
        out.add('<p>${_inline(trimmed).replaceAll('\n', '<br>')}</p>');
      }
    }
  }

  var at = 0;
  for (final f in _fence.allMatches(source)) {
    prose(source.substring(at, f.start));
    final lang = f[2]!.toLowerCase();
    final body = f[3]!;
    out.add(
      lang == 'html'
          ? body
          : '<pre><code${lang.isEmpty ? '' : ' class="language-$lang"'}>${_escape(body)}</code></pre>',
    );
    at = f.end;
  }
  prose(source.substring(at));
  return out.join('\n');
}

String _css(Color c) =>
    'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(3)})';

/// How many of the latest messages the canvas always lays out; older ones
/// are skipped while off screen (CSS content-visibility).
const tavernCanvasNear = 20;

/// The page the canvas loads once: ST's structure and colour variables, the
/// story's size and colours, and our script (allowed by [nonce]) that draws
/// what render()/stream() hand it and reports a long press on a message to
/// the `DshTavern` channel. [noScripts] and [offline] are 酒馆设置 › 安全's
/// choices, as for islands.
String tavernCanvasDocument({
  required Color text,
  required Color accent,
  required Color muted,
  required Color quote,
  required Color emphasis,
  required Color userTint,
  required double fontSize,
  required double lineHeight,
  required String nonce,
  String userLabel = '',
  TavernCanvasLabels labels = const TavernCanvasLabels(),
  bool noScripts = false,
  bool offline = false,
}) {
  final policy = noScripts || offline
      ? [
          if (offline) "default-src 'none'",
          if (offline) 'img-src data: blob:',
          if (offline) 'media-src data: blob:',
          if (offline) 'font-src data:',
          if (offline) "style-src 'unsafe-inline' data:",
          if (noScripts) "script-src 'nonce-$nonce'" else "script-src 'unsafe-inline' 'unsafe-eval' 'nonce-$nonce'",
          if (noScripts) "script-src-attr 'none'",
        ].join('; ')
      : null;
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${policy == null ? '' : '<meta http-equiv="Content-Security-Policy" content="$policy">'}
<style>
:root{
  --dsh-text:${_css(text)};--dsh-accent:${_css(accent)};--dsh-muted:${_css(muted)};--dsh-user:${_css(userTint)};
  --SmartThemeBodyColor:var(--dsh-text);--SmartThemeQuoteColor:${_css(quote)};--SmartThemeEmColor:${_css(emphasis)};
  --SmartThemeUnderlineColor:var(--dsh-accent);--SmartThemeBorderColor:var(--dsh-muted);
  --mainFontSize:${fontSize}px;
}
html,body{margin:0;padding:0;background:transparent;}
body{color:var(--dsh-text);font:var(--mainFontSize)/$lineHeight system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;overflow-wrap:anywhere;-webkit-text-size-adjust:100%;}
#chat{display:flex;flex-direction:column;gap:14px;padding:12px 16px 24px;}
.mes{display:flex;flex-direction:column;}
.mes.far{content-visibility:auto;contain-intrinsic-size:auto 160px;}
.mes .ch_name{font-size:.82em;font-weight:600;color:var(--dsh-accent);margin-bottom:2px;}
.mes[is_user="true"] .ch_name{color:var(--dsh-muted);}
.mes[is_user="true"] .mes_text{background:var(--dsh-user);border-radius:16px;padding:8px 12px;align-self:flex-end;max-width:85%;box-sizing:border-box;}
.mes[is_user="true"] .mes_block{align-items:flex-end;}
.mes[is_system="true"] .mes_text{color:var(--dsh-muted);font-style:italic;}
.mes_block{display:flex;flex-direction:column;}
.mes_text p{margin:0 0 .6em;}
.mes_text p:last-child{margin-bottom:0;}
.mes_text q{color:var(--SmartThemeQuoteColor);quotes:none;}
.mes_text q::before,.mes_text q::after{content:none;}
.mes_text em{color:var(--SmartThemeEmColor);}
.mes_text a{color:var(--dsh-accent);}
.mes_text img,.mes_text video,.mes_text svg{max-width:100%;height:auto;}
.mes_text pre{white-space:pre-wrap;}
.mes[data-streaming] .mes_text>:last-child::after,.mes[data-streaming] .mes_text:empty::after{content:"\\25CF";color:var(--dsh-muted);margin-left:3px;font-size:.6em;vertical-align:middle;}
</style></head>
<body><div id="chat"></div>
<script nonce="$nonce">
(function(){
  var chat=document.getElementById('chat');
  var userLabel=${jsonEncode(userLabel)};
  // A card's scripts: off with 酒馆设置 › 安全 › 不运行卡的脚本 (the page's
  // policy would refuse them too). Never given this page's own nonce.
  var runScripts=${!noScripts},running=Promise.resolve();
  function inert(s){var t=(s.getAttribute('type')||'').trim().toLowerCase();return t!==''&&!/^(text|application)[/](java|ecma)script\$|^module\$/.test(t);}
  // innerHTML leaves <script> inert: each is rebuilt in place, one after
  // another in document order (and after any earlier message's), an
  // external one loaded before the next runs.
  function runIn(els){
    els.forEach(function(m){
      [].slice.call(m.querySelectorAll('script')).forEach(function(old){
        running=running.then(function(){return new Promise(function(done){
          if(!m.isConnected||!old.parentNode||inert(old)){done();return;}
          var s=document.createElement('script');
          for(var a=0;a<old.attributes.length;a++){var at=old.attributes[a];if(at.name!=='nonce')s.setAttribute(at.name,at.value);}
          if(old.hasAttribute('src')){s.async=false;s.onload=s.onerror=function(){done();};old.parentNode.replaceChild(s,old);}
          else{s.text=old.text;old.parentNode.replaceChild(s,old);done();}
        });});
      });
    });
  }
  function nearBottom(){return window.innerHeight+window.scrollY>=document.body.scrollHeight-80;}
  function toBottom(){window.scrollTo(0,document.body.scrollHeight);}
  function sig(e){return JSON.stringify([e.name||'',!!e.user,!!e.system,e.html||'']);}
  function mes(e){
    var m=document.createElement('div');
    m.className='mes';
    m.setAttribute('mesid',String(e.mesid));
    m.setAttribute('ch_name',e.name||'');
    m.setAttribute('is_user',e.user?'true':'false');
    m.setAttribute('is_system',e.system?'true':'false');
    m.dataset.node=e.node||'';
    var block=document.createElement('div');block.className='mes_block';
    var name=document.createElement('div');name.className='ch_name';
    var nameText=document.createElement('span');nameText.className='name_text';
    nameText.textContent=e.user?(userLabel||e.name||''):(e.name||'');
    name.appendChild(nameText);
    var text=document.createElement('div');text.className='mes_text';
    text.innerHTML=e.html||'';
    block.appendChild(name);block.appendChild(text);m.appendChild(block);
    return m;
  }
  var stream=null;
  // dsh.call(method, params): a Promise of what the engine answers (the
  // result, or an Error carrying code/committed/fieldPath).
  var calls={},callSeq=0;
  window.dsh={
    call:function(method,params){
      return new Promise(function(ok,no){
        var id=++callSeq;calls[id]={ok:ok,no:no};
        post({type:'call',id:id,method:method,params:params===undefined?{}:params});
      });
    },
    answer:function(r){
      var c=r&&calls[r.id];if(!c)return;delete calls[r.id];
      if(r.ok){c.ok(r.result);return;}
      var x=r.error||{};var e=new Error(x.message||x.code||'failed');
      e.code=x.code;e.committed=!!x.committed;e.fieldPath=x.fieldPath==null?null:x.fieldPath;
      c.no(e);
    },
    render:function(list){
      var stay=nearBottom()||!chat.firstChild;
      if(stream){stream.remove();stream=null;}
      // A message drawn as it was is kept, not drawn again: its HTML (and
      // anything a card put in it) stays as it is.
      var kept={},fresh=[];
      for(var c=chat.firstElementChild;c;c=c.nextElementSibling){if(c.dataset.node)kept[c.dataset.node]=c;}
      for(var i=0;i<list.length;i++){
        var e=list[i],key=sig(e),m=kept[e.node||''];
        if(m&&m._dsh===key){delete kept[e.node];m.setAttribute('mesid',String(e.mesid));}
        else{m=mes(e);m._dsh=key;fresh.push(m);}
        // Only the latest few are always laid out; older ones are skipped
        // while off screen.
        m.classList.toggle('far',i<list.length-$tavernCanvasNear);
        var at=chat.children[i];
        if(at!==m)chat.insertBefore(m,at||null);
      }
      while(chat.children.length>list.length)chat.lastElementChild.remove();
      // A newly drawn message's scripts run, once the page has the engine's
      // snapshot for their getters (or has been told it cannot).
      var scripted=fresh.filter(function(m){return m.querySelector('script');});
      if(runScripts&&scripted.length){var go=function(){runIn(scripted);};dsh.scripts.ready().then(go,go);}
      if(stay)toBottom();
    },
    stream:function(name,html){
      var stay=nearBottom();
      if(html===null){if(stream){stream.remove();stream=null;}return;}
      if(!stream){stream=mes({mesid:chat.children.length,node:'',name:name,html:'',user:false,system:false});stream.dataset.streaming='1';chat.appendChild(stream);}
      else if(stream.getAttribute('ch_name')!==(name||'')){stream.setAttribute('ch_name',name||'');stream.querySelector('.name_text').textContent=name||'';}
      stream.querySelector('.mes_text').innerHTML=html;
      if(stay)toBottom();
    }
  };
  // Card scripts' synchronous getters (酒馆助手's shape, P2 §4.3): a copy of
  // what the engine had at the snapshot, written through with dsh.call. A
  // write reads back at once, then settles to what the engine kept, or back
  // to that if it was refused; only the latest write to a scope counts.
  var vars={},msgs=[],loading=null;
  function clone(v){return v===undefined?undefined:JSON.parse(JSON.stringify(v));}
  function slot(o){
    var type=(o&&o.type)||'chat';
    if(type==='message'){
      var id=o&&o.message_id;
      if(id===undefined||id==='latest'||id===-1)return {key:'message'};
      if(typeof id!=='number'||id%1!==0)throw new TypeError('message_id is a message number');
      if(id<0)id=msgs.length+id;
      return {key:'message:'+id,target:{scope:'message',messageId:id},id:id};
    }
    if(type==='global'||type==='chat'||type==='character')return {key:type,target:{scope:type}};
    throw new TypeError('Variables of type '+type+' are not kept on this page');
  }
  function kept(s){
    var e=vars[s.key];
    if(e)return e;
    var m=s.id===undefined?null:msgs[s.id];
    return vars[s.key]={target:s.target||{scope:'message'},version:null,value:m&&m.data?m.data:{},seq:0};
  }
  function getVariables(o){var e=kept(slot(o));return clone(e.pending!==undefined?e.pending:e.value);}
  function replaceVariables(variables,o){
    var e=kept(slot(o)),mine=++e.seq;
    e.pending=clone(variables)||{};
    return dsh.call('replaceVariables',{target:e.target,value:variables}).then(function(r){
      e.value=r.value;e.version=r.version;
      if(e.seq===mine)e.pending=undefined;
      return clone(r.value);
    },function(x){if(e.seq===mine)e.pending=undefined;throw x;});
  }
  // The engine's deliveries (cache): held until the snapshot is in, then
  // only those after its lastSeq; variables update in place (a write still
  // in flight stays on top), a message rewritten in place is replaced, and
  // anything else about the path — a message gone or moved, a revision this
  // copy did not come from — is read afresh as a new snapshot.
  var loaded=false,lastSeq=0,pathRev=null,held=[];
  function sameRef(a,b){return !!a&&!!b&&a.chatId===b.chatId&&a.nodeId===b.nodeId;}
  function setVar(v){
    var t=v.target||{};
    if(t.scope!=='message'){var e=vars[t.scope]||(vars[t.scope]={seq:0});e.target=t;e.version=v.version;e.value=v.value;return;}
    var latest=vars.message;
    if(latest&&latest.target&&sameRef(latest.target.messageRef,t.messageRef)){latest.version=v.version;latest.value=v.value;}
    for(var i=0;i<msgs.length;i++)if(sameRef(msgs[i].ref,t.messageRef)){
      msgs[i].data=v.value;var at=vars['message:'+i];if(at){at.version=v.version;at.value=v.value;}
    }
  }
  function reload(){loaded=false;loading=null;dsh.scripts.ready().catch(function(){});}
  function apply(d){
    if(typeof d.seq!=='number'||d.seq<=lastSeq)return;
    lastSeq=d.seq;
    var x=d.delta;if(!x)return;
    (x.variables||[]).forEach(setVar);
    if(x.baseRevision===x.newRevision)return;
    var moved=(x.removedRefs||[]).length||Object.keys(x.indexChanges||{}).length||x.baseRevision!==pathRev;
    var up=x.upsertMessages||[];
    for(var u=0;!moved&&u<up.length;u++){
      var found=-1;for(var i=0;i<msgs.length;i++)if(sameRef(msgs[i].ref,up[u].ref))found=i;
      if(found<0)moved=true;else msgs[found]=up[u];
    }
    if(moved){reload();return;}
    pathRev=x.newRevision;
  }
  dsh.scripts={
    ready:function(){
      if(!loading)loading=dsh.call('snapshot').then(function(s){
        msgs=s.messages||[];
        for(var k in vars)if(k.indexOf('message:')===0&&vars[k].pending===undefined)delete vars[k];
        (s.variables||[]).forEach(function(v){
          var e=vars[v.target.scope]||(vars[v.target.scope]={seq:0});
          e.target=v.target;e.version=v.version;e.value=v.value;
        });
        lastSeq=s.lastSeq||0;pathRev=s.pathRevision||null;loaded=true;
        var waiting=held;held=[];waiting.forEach(apply);
        return true;
      },function(x){loading=null;throw x;});
      return loading;
    },
    deliver:function(d){
      if(!d||d.kind!=='cache')return;
      // Not asked for yet: a snapshot taken later covers what was dropped.
      if(!loaded){if(!loading&&held.length>=200)held=[];held.push(d);return;}
      apply(d);
    },
    getVariables:getVariables,
    replaceVariables:replaceVariables
  };
  if(!window.getVariables)window.getVariables=getVariables;
  if(!window.replaceVariables)window.replaceVariables=replaceVariables;
  var hold=null,from=null;
  function post(o){if(window.DshTavern)DshTavern.postMessage(JSON.stringify(o));}
  function owner(t){while(t&&t!==chat){if(t.classList&&t.classList.contains('mes'))return t;t=t.parentNode;}return null;}
  chat.addEventListener('touchstart',function(ev){
    var m=owner(ev.target);if(!m||!m.dataset.node)return;
    from=ev.touches[0];
    hold=setTimeout(function(){hold=null;post({type:'menu',node:m.dataset.node});},550);
  },{passive:true});
  function cancel(){if(hold){clearTimeout(hold);hold=null;}}
  chat.addEventListener('touchmove',function(ev){
    if(!from||!hold)return;var t=ev.touches[0];
    if(Math.abs(t.clientX-from.clientX)+Math.abs(t.clientY-from.clientY)>10)cancel();
  },{passive:true});
  chat.addEventListener('touchend',cancel);
  chat.addEventListener('touchcancel',cancel);
  chat.addEventListener('contextmenu',function(ev){
    var m=owner(ev.target);if(!m||!m.dataset.node)return;
    if(String(window.getSelection())==='')ev.preventDefault();
  });
  // Component tags as Web Components: their own look in a shadow root, with
  // parts (::part(paper) …) and --dsh-* variables left for a card to restyle.
  var L=${jsonEncode(labels.toJson())};
  function fill(s,k,v){return s.split('{'+k+'}').join(v);}
  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  var base=':host{display:block;margin:6px 0;color:var(--dsh-text);font:inherit;font-style:normal;}'+
    '[part~=card]{border:1px solid var(--dsh-card-border,rgba(127,127,127,.28));border-radius:14px;padding:12px 14px;background:var(--dsh-card,rgba(127,127,127,.06));}'+
    '[part~=head]{display:flex;gap:8px;align-items:baseline;font-weight:600;font-size:.92em;}'+
    '[part~=head] [part~=title]{flex:1;color:var(--dsh-accent);}'+
    '[part~=meta]{font-weight:400;font-size:.8em;color:var(--dsh-muted);}'+
    '[part~=body]{margin-top:8px;}';
  function define(tag,css,html){
    if(customElements.get(tag))return;
    customElements.define(tag,class extends HTMLElement{
      connectedCallback(){
        if(this.shadowRoot)return;
        var root=this.attachShadow({mode:'open'});
        root.innerHTML='<style>'+base+css+'</style>'+html(this);
      }
    });
  }
  function attr(el,names){for(var i=0;i<names.length;i++){var v=el.getAttribute(names[i]);if(v&&v.trim())return v.trim();}return null;}
  define('dsh-letter','[part~=card]{background:var(--dsh-letter-paper,rgba(232,211,166,.24));line-height:1.75;}',function(el){
    var from=attr(el,['from','sender','author']);var date=attr(el,['date','time']);
    return '<div part="card paper"><div part="head"><span part="title">'+esc(from?fill(L.letterFrom,'from',from):L.letter)+'</span>'+(date?'<span part="meta">'+esc(date)+'</span>':'')+'</div><div part="body"><slot></slot></div></div>';
  });
  define('dsh-item','[part~=card]{display:flex;gap:12px;align-items:flex-start;padding:10px 14px 10px 12px;}[part~=icon]{width:34px;height:34px;border-radius:10px;background:var(--dsh-item-icon,rgba(127,127,127,.14));display:flex;align-items:center;justify-content:center;flex:none;}[part~=name]{font-weight:600;}[part~=taken]{margin-left:8px;font-size:.75em;padding:1px 7px;border-radius:6px;background:var(--dsh-item-taken,rgba(60,160,90,.18));}[part~=body]{margin-top:2px;font-size:.88em;color:var(--dsh-muted);}',function(el){
    var name=attr(el,['name','title']);var taken=el.hasAttribute('take')||el.hasAttribute('taken');
    return '<div part="card item"><div part="icon">✦</div><div><div><span part="name">'+esc(name||'')+'</span>'+(taken?'<span part="taken">'+esc(L.taken)+'</span>':'')+'</div><div part="body"><slot></slot></div></div></div>';
  });
  define('dsh-clue',':host{transform:rotate(-.7deg);}[part~=card]{background:var(--dsh-clue-note,rgba(245,215,110,.28));}',function(el){
    var title=attr(el,['title','name']);
    return '<div part="card note"><div part="head"><span part="title">'+esc(title||L.clue)+'</span></div><div part="body"><slot></slot></div></div>';
  });
  define('dsh-phone','[part~=card]{max-width:360px;}[part~=bubble]{margin-top:8px;padding:8px 12px;border-radius:4px 14px 14px 14px;background:var(--dsh-phone-bubble,rgba(127,127,127,.14));}',function(el){
    var from=attr(el,['from','sender','name']);var time=attr(el,['time','date']);
    return '<div part="card phone"><div part="head"><span part="title">'+esc(from?fill(L.phoneFrom,'from',from):L.phone)+'</span>'+(time?'<span part="meta">'+esc(time)+'</span>':'')+'</div><div part="bubble"><slot></slot></div></div>';
  });
  define('dsh-roll','[part~=head]{align-items:center;}[part~=score]{font-variant-numeric:tabular-nums;}[part~=result]{font-weight:700;}.ok{color:var(--dsh-success,#2f8a4c);}.bad{color:var(--dsh-danger,#c0392b);}[part~=body]{margin-top:4px;font-size:.8em;color:var(--dsh-muted);}',function(el){
    var skill=attr(el,['skill','check','name','title']);var value=attr(el,['value','roll','score']);var target=attr(el,['target','dc','difficulty','against']);var result=attr(el,['result','outcome']);
    var r=(result||'').toLowerCase();var ok=/^(success|pass|passed|succeeded|成功|大成功|通过)\$/.test(r);var bad=/^(fail|failure|failed|失败|大失败)\$/.test(r);
    var label=ok?L.success:(bad?L.failure:result);
    var score=[value,target].filter(function(x){return x;}).join(' / ');
    return '<div part="card roll"><div part="head"><span part="title">'+esc(skill?fill(L.rollCheck,'skill',skill):L.roll)+'</span>'+(score?'<span part="score">'+esc(score)+'</span>':'')+(label?'<span part="result" class="'+(ok?'ok':bad?'bad':'')+'">'+esc(label)+'</span>':'')+'</div><div part="body"><slot></slot></div></div>';
  });
  define('dsh-notice',':host{text-align:center;font-size:.85em;color:var(--dsh-muted);}',function(){return '<slot></slot>';});
  define('dsh-game',':host{text-align:center;font-size:.85em;color:var(--dsh-muted);}',function(){return '▷ '+esc(L.game);});
  post({type:'ready'});
})();
</script></body></html>''';
}
