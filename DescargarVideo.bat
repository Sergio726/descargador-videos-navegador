<# :
@echo off
rem ==== Descargador de videos del navegador (bat + PowerShell + Python en un solo archivo) ====
setlocal
set "DV_SCRIPT=%~f0"
title Descargador de videos
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:DV_SCRIPT, [Text.Encoding]::UTF8))"
if errorlevel 1 pause
endlocal
exit /b
#>

# ---------------------------------------------------------------------------
#  A partir de aca es PowerShell. El bloque de arriba es un comentario <# #>
#  para PowerShell y codigo normal para cmd.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppDir     = Join-Path $env:LOCALAPPDATA 'DescargadorVideos'
$BinDir     = Join-Path $AppDir 'bin'
$TmpDir     = Join-Path $AppDir 'tmp'
$ProfileDir = Join-Path $AppDir 'perfil-navegador'
$SnifferPy  = Join-Path $AppDir 'buscar_video.py'
New-Item -ItemType Directory -Force -Path $BinDir, $TmpDir | Out-Null

# ---------------------------------------------------------------------------
#  Script Python (Playwright + Edge): abre la pagina, le da play al video y
#  captura las direcciones reales de video que pide el reproductor.
# ---------------------------------------------------------------------------
$SnifferCode = @'
import sys, json, re, time
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

page_url, out_path, mode, profile, ua, cookies_path = sys.argv[1:7]
visible = (mode == 'visible')

EXT   = re.compile(r'\.(m3u8|mpd|mp4|webm|m4v|mov|flv|mkv)(?:$|[?#])', re.I)
SKIP  = re.compile(r'\.(ts|m4s|aac|vtt|key)(?:$|[?#])|/seg[-_]?\d|/frag|/chunk[-_]?\d|init\.mp4', re.I)
EMBED = re.compile(r'youtube\.com/embed|youtube-nocookie|player\.vimeo|vimeo\.com/video|dailymotion\.com/embed|'
                   r'wistia|jwplayer|jwplatform|brightcove|vidyard|loom\.com/embed|streamable|ok\.ru/videoembed|'
                   r'facebook\.com/plugins/video|mediadelivery|bunnycdn|videodelivery|cloudflarestream|kaltura|'
                   r'panopto|hotmart|pandavideo|vturb|converteai|spotlightr|vooplayer|sproutvideo|vdocipher', re.I)

found = {}
state = {'title': '', 'cookies': []}

def add(url, kind, size=0, master=False):
    c = found.get(url)
    if c:
        c['size'] = max(c['size'], size)
        c['master'] = c['master'] or master
        return
    found[url] = {'url': url, 'kind': kind, 'size': size, 'master': master, 'order': len(found)}

def on_response(r):
    try:
        u = r.url
        if not u.startswith('http'):
            return
        ct = (r.headers.get('content-type') or '').lower()
        m = EXT.search(u)
        ext = m.group(1).lower() if m else ''
        if 'mpegurl' in ct or ext == 'm3u8':
            master = False
            try:
                master = '#EXT-X-STREAM-INF' in r.text()
            except Exception:
                pass
            add(u, 'hls', 0, master)
        elif 'dash+xml' in ct or ext == 'mpd':
            add(u, 'dash')
        elif (ct.startswith('video/') and 'mp2t' not in ct) or ext in ('mp4', 'webm', 'm4v', 'mov', 'flv', 'mkv'):
            if SKIP.search(u):
                return
            size = 0
            cr = r.headers.get('content-range') or ''
            cl = r.headers.get('content-length') or ''
            if '/' in cr and cr.split('/')[-1].isdigit():
                size = int(cr.split('/')[-1])
            elif cl.isdigit():
                size = int(cl)
            if 0 < size < 300000:
                return  # iconos o clips minusculos
            add(u, 'file', size)
    except Exception:
        pass

PLAY_JS = "() => { document.querySelectorAll('video,audio').forEach(v => { try { v.muted = true; v.play().catch(() => {}); } catch (e) {} }); }"
PLAY_SELECTORS = ['.vjs-big-play-button', '.plyr__control--overlaid', '.jw-icon-display', '.ytp-large-play-button',
                  'button[aria-label*="play" i]', 'button[title*="play" i]', '[class*="play-button" i]',
                  '[class*="playButton" i]', '[class*="btn-play" i]', '[class*="play_button" i]']

def poke(page):
    for fr in page.frames:
        for s in PLAY_SELECTORS:
            try:
                el = fr.query_selector(s)
                if el and el.is_visible():
                    el.click(timeout=1500, force=True)
                    break
            except Exception:
                pass
        try:
            fr.evaluate(PLAY_JS)
        except Exception:
            pass

def snapshot(ctx):
    try:
        pages = [p for p in ctx.pages if not p.is_closed()]
        if pages:
            t = pages[0].title()
            if t:
                state['title'] = t
        for p in pages:
            for fr in p.frames:
                if fr != p.main_frame and fr.url.startswith('http') and EMBED.search(fr.url):
                    add(fr.url, 'embed')
        state['cookies'] = ctx.cookies()
    except Exception:
        pass

def write_cookies(path, cookies):
    lines = ['# Netscape HTTP Cookie File']
    for c in cookies:
        dom = c.get('domain', '')
        exp = int(c['expires']) if c.get('expires', -1) and c['expires'] > 0 else 0
        lines.append('\t'.join([dom, 'TRUE' if dom.startswith('.') else 'FALSE', c.get('path', '/'),
                                'TRUE' if c.get('secure') else 'FALSE', str(exp), c['name'], c['value']]))
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        profile, channel='msedge', headless=not visible, user_agent=ua or None,
        viewport=None if visible else {'width': 1280, 'height': 800},
        args=['--autoplay-policy=no-user-gesture-required'] + ([] if visible else ['--mute-audio']))
    ctx.on('response', on_response)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    try:
        page.goto(page_url, wait_until='domcontentloaded', timeout=45000)
    except Exception as e:
        print('  AVISO: la pagina tardo en cargar (%s)' % str(e).splitlines()[0], file=sys.stderr)

    if visible:
        deadline = time.time() + 600
        while time.time() < deadline:
            try:
                pages = [pg for pg in ctx.pages if not pg.is_closed()]
                if not pages:
                    break
                snapshot(ctx)
                pages[0].wait_for_timeout(1000)
            except Exception:
                break
    else:
        page.wait_for_timeout(3000)
        start, pokes, first_stream = time.time(), 0, None
        while time.time() - start < 25:
            if pokes < 3:
                poke(page)
                pokes += 1
            page.wait_for_timeout(2500)
            snapshot(ctx)
            if any(c['kind'] in ('hls', 'dash') for c in found.values()):
                if first_stream is None:
                    first_stream = time.time()
                elif time.time() - first_stream > 4:
                    break
        snapshot(ctx)
    try:
        ctx.close()
    except Exception:
        pass

write_cookies(cookies_path, state['cookies'])
rank = {'hls': 1, 'dash': 2, 'file': 3, 'embed': 4}
cands = sorted(found.values(), key=lambda c: (0 if c['master'] else rank[c['kind']], -c['size'], c['order']))
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump({'title': state['title'], 'page': page_url, 'candidates': cands[:15]}, f, ensure_ascii=False)
'@
[IO.File]::WriteAllText($SnifferPy, $SnifferCode, (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
#  Extension de Chrome: detecta el video que se reproduce en TU Chrome (con tu
#  sesion) y lo copia al portapapeles para que este descargador lo use.
# ---------------------------------------------------------------------------
$ExtDir = Join-Path $AppDir 'extension-chrome'
New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null
$ExtFiles = @{}
$ExtFiles['manifest.json'] = @'
{
  "manifest_version": 3,
  "name": "Descargador de videos (puente)",
  "version": "1.0",
  "description": "Detecta el video que se reproduce y lo pasa a DescargarVideo.bat",
  "permissions": ["webRequest", "cookies", "storage", "clipboardWrite"],
  "host_permissions": ["<all_urls>"],
  "background": { "service_worker": "background.js" },
  "action": { "default_popup": "popup.html", "default_title": "Descargador de videos" }
}
'@
$ExtFiles['background.js'] = @'
const EXT = /\.(m3u8|mpd|mp4|webm|m4v|mov|flv|mkv)(?:$|[?#])/i;
const SKIP = /\.(ts|m4s|aac|vtt|key)(?:$|[?#])|\/seg[-_]?\d|\/frag|\/chunk[-_]?\d|init\.mp4|googlevideo\.com/i;
const key = id => 'tab' + id;
let queue = Promise.resolve();

async function getList(tabId) { const k = key(tabId); return (await chrome.storage.session.get(k))[k] || []; }
async function setList(tabId, list) {
  await chrome.storage.session.set({ [key(tabId)]: list });
  try { await chrome.action.setBadgeText({ tabId, text: list.length ? String(list.length) : '' }); } catch (e) {}
}
function add(tabId, item) {
  queue = queue.then(async () => {
    const list = await getList(tabId);
    const prev = list.find(x => x.url === item.url);
    if (prev) { prev.size = Math.max(prev.size, item.size); prev.master = prev.master || item.master; }
    else { item.order = list.length; list.push(item); if (list.length > 30) list.shift(); }
    await setList(tabId, list);
  }).catch(() => {});
}

chrome.webRequest.onBeforeRequest.addListener(d => {
  if (d.tabId >= 0) queue = queue.then(() => setList(d.tabId, [])).catch(() => {});
}, { urls: ['<all_urls>'], types: ['main_frame'] });

chrome.webRequest.onHeadersReceived.addListener(d => {
  if (d.tabId < 0 || !/^https?:/.test(d.url)) return;
  const u = d.url, h = {};
  for (const x of d.responseHeaders || []) h[x.name.toLowerCase()] = x.value || '';
  const ct = (h['content-type'] || '').toLowerCase();
  const m = u.match(EXT), ext = m ? m[1].toLowerCase() : '';
  if (ct.includes('mpegurl') || ext === 'm3u8') {
    add(d.tabId, { url: u, kind: 'hls', size: 0, master: false });
    fetch(u, { credentials: 'include' }).then(r => r.text())
      .then(t => { if (t.includes('#EXT-X-STREAM-INF')) add(d.tabId, { url: u, kind: 'hls', size: 0, master: true }); })
      .catch(() => {});
  } else if (ct.includes('dash+xml') || ext === 'mpd') {
    add(d.tabId, { url: u, kind: 'dash', size: 0, master: false });
  } else if ((ct.startsWith('video/') && !ct.includes('mp2t')) || ['mp4', 'webm', 'm4v', 'mov', 'flv', 'mkv'].includes(ext)) {
    if (SKIP.test(u)) return;
    let size = 0;
    const cr = h['content-range'] || '', cl = h['content-length'] || '';
    if (cr.includes('/') && /^\d+$/.test(cr.split('/').pop())) size = +cr.split('/').pop();
    else if (/^\d+$/.test(cl)) size = +cl;
    if (size > 0 && size < 300000) return;
    add(d.tabId, { url: u, kind: 'file', size, master: false });
  }
}, { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'other'] }, ['responseHeaders']);

chrome.tabs.onRemoved.addListener(id => chrome.storage.session.remove(key(id)));
'@
$ExtFiles['popup.html'] = @'
<!doctype html>
<html><head><meta charset="utf-8">
<style>
  body { font: 13px "Segoe UI", sans-serif; width: 430px; margin: 0; padding: 12px; background: #fff; color: #111; }
  h1 { font-size: 14px; margin: 0 0 10px; }
  .it { border: 1px solid #ddd; border-radius: 6px; padding: 8px; margin-bottom: 8px; }
  .t { font-weight: 600; }
  .u { color: #666; word-break: break-all; font-size: 11px; margin: 4px 0 6px; }
  button { background: #0b6bcb; color: #fff; border: 0; border-radius: 4px; padding: 6px 10px; cursor: pointer; }
  button.ok { background: #0a7d2c; }
  .empty, .tip { color: #555; }
</style></head>
<body>
  <h1>Videos detectados en esta pestana</h1>
  <div id="list"></div>
  <p class="tip">Despues de copiar, abri <b>DescargarVideo.bat</b>: el video aparece como opcion 1.</p>
  <script src="popup.js"></script>
</body></html>
'@
$ExtFiles['popup.js'] = @'
const names = { hls: 'Stream HLS', dash: 'Stream DASH', file: 'Archivo de video' };
const rank = { hls: 1, dash: 2, file: 3 };

async function copy(it, tab, btn) {
  const seen = new Set(), lines = ['# Netscape HTTP Cookie File'];
  for (const u of [it.url, tab.url]) {
    let cookies = [];
    try { cookies = await chrome.cookies.getAll({ url: u }); } catch (e) {}
    for (const c of cookies) {
      const id = c.domain + '|' + c.path + '|' + c.name;
      if (seen.has(id)) continue;
      seen.add(id);
      lines.push([c.domain, c.hostOnly ? 'FALSE' : 'TRUE', c.path, c.secure ? 'TRUE' : 'FALSE',
                  c.session ? 0 : Math.floor(c.expirationDate || 0), c.name, c.value].join('\t'));
    }
  }
  const payload = { dv: 1, url: it.url, kind: it.kind, page: tab.url, title: tab.title,
                    ua: navigator.userAgent, cookies: lines.join('\n') + '\n' };
  await navigator.clipboard.writeText(JSON.stringify(payload));
  document.querySelectorAll('button').forEach(b => { b.className = ''; b.textContent = 'Copiar para el descargador'; });
  btn.className = 'ok';
  btn.textContent = 'Copiado - ahora abri DescargarVideo.bat';
}

(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const k = 'tab' + tab.id;
  const list = (await chrome.storage.session.get(k))[k] || [];
  list.sort((a, b) => (b.master - a.master) || (rank[a.kind] - rank[b.kind]) || (b.size - a.size) || (a.order - b.order));
  const el = document.getElementById('list');
  if (!list.length) {
    el.innerHTML = '<p class="empty">Todavia no detecte ningun video.<br>Dale <b>PLAY</b> al video, espera unos segundos y volve a abrir este panel.</p>';
    return;
  }
  list.forEach((it, i) => {
    const d = document.createElement('div'); d.className = 'it';
    const t = document.createElement('div'); t.className = 't';
    let label = (i + 1) + ') ' + names[it.kind];
    if (it.master) label += ' (todas las calidades)';
    if (it.size) label += ' - ' + (it.size / 1048576).toFixed(1) + ' MB';
    t.textContent = label;
    const u = document.createElement('div'); u.className = 'u';
    u.textContent = it.url.length > 140 ? it.url.slice(0, 137) + '...' : it.url;
    const b = document.createElement('button'); b.textContent = 'Copiar para el descargador';
    b.onclick = () => copy(it, tab, b);
    d.append(t, u, b); el.append(d);
  });
})();
'@
foreach ($name in $ExtFiles.Keys) {
    [IO.File]::WriteAllText((Join-Path $ExtDir $name), $ExtFiles[$name], (New-Object Text.UTF8Encoding($false)))
}

# ---------- Utilidades de pantalla ----------
function Show-Title {
    Clear-Host
    Write-Host ''
    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host '        DESCARGADOR DE VIDEOS DEL NAVEGADOR' -ForegroundColor Cyan
    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host ''
}

function Show-Error {
    param([string]$Titulo, [string[]]$Detalle, [string]$Sugerencia)
    Write-Host ''
    Write-Host "DescargarVideo : $Titulo" -ForegroundColor Red -BackgroundColor Black
    foreach ($l in $Detalle) {
        if ($l -and $l.Trim()) { Write-Host "    $l" -ForegroundColor Red -BackgroundColor Black }
    }
    Write-Host '    + CategoryInfo          : NotSpecified: (:) [DescargarVideo], Exception' -ForegroundColor Red -BackgroundColor Black
    Write-Host '    + FullyQualifiedErrorId : DownloadFailed' -ForegroundColor Red -BackgroundColor Black
    if ($Sugerencia) {
        Write-Host ''
        Write-Host "  Sugerencia: $Sugerencia" -ForegroundColor Yellow
    }
    Write-Host ''
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    $r = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return $r.Trim()
}

function Read-Timeout {
    # Pregunta S/n con cuenta regresiva: si no se toca nada, elige $Default.
    # Con -Valid se puede usar para numeros: -Valid '1','2','3' -Opciones '1-3'
    param([string]$Prompt, [string]$Default = 's', [int]$Seconds = 5, [string[]]$Valid = @('s', 'n'), [string]$Opciones)
    if (-not $Opciones) { $Opciones = if ($Default -eq 's') { 'S/n' } else { 's/N' } }
    if ([Console]::IsInputRedirected) { return Read-Default "$Prompt ($Opciones)" $Default }
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }   # descartar teclas viejas
    $opciones = $Opciones
    $fin = (Get-Date).AddSeconds($Seconds)
    $respuesta = $null
    while (-not $respuesta) {
        $quedan = [math]::Ceiling(($fin - (Get-Date)).TotalSeconds)
        if ($quedan -le 0) { $respuesta = $Default; break }
        Write-Host ("`r$Prompt ($opciones) - se elige '{0}' en {1} s... " -f $Default.ToUpper(), $quedan) -NoNewline -ForegroundColor White
        $hasta = (Get-Date).AddMilliseconds(200)
        while ((Get-Date) -lt $hasta -and -not $respuesta) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                $c = ([string]$k.KeyChar).ToLower()
                if ($k.Key -eq 'Enter') { $respuesta = $Default }
                elseif ($c -and $Valid -contains $c) { $respuesta = $c }
            }
            Start-Sleep -Milliseconds 50
        }
    }
    Write-Host ("`r$Prompt ($opciones): {0}                         " -f $respuesta) -ForegroundColor White
    return $respuesta
}

# ---------- Herramientas (yt-dlp, ffmpeg, Python) ----------
function Get-Tool {
    param([string]$Name)
    $local = Join-Path $BinDir "$Name.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-YtDlp {
    Write-Host '  Descargando yt-dlp (solo la primera vez)...' -ForegroundColor Yellow
    $dest = Join-Path $BinDir 'yt-dlp.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $dest
    return $dest
}

function Install-Ffmpeg {
    Write-Host '  Descargando ffmpeg (solo la primera vez, ~100 MB)...' -ForegroundColor Yellow
    $zip = Join-Path $TmpDir 'ffmpeg.zip'
    $ext = Join-Path $TmpDir 'ffmpeg'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' -OutFile $zip
    if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $ext -Force
    foreach ($exe in 'ffmpeg.exe', 'ffprobe.exe') {
        $f = Get-ChildItem -Path $ext -Recurse -Filter $exe | Select-Object -First 1
        if ($f) { Copy-Item $f.FullName (Join-Path $BinDir $exe) -Force }
    }
    Remove-Item $zip, $ext -Recurse -Force -ErrorAction SilentlyContinue
    return (Join-Path $BinDir 'ffmpeg.exe')
}

function Get-PythonPlaywright {
    # Devuelve el python que tiene Playwright; si hay python sin Playwright, lo instala.
    $pys = @('python', 'py') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
    foreach ($py in $pys) {
        & $py -c "import playwright" 2>$null
        if ($LASTEXITCODE -eq 0) { return $py }
    }
    foreach ($py in $pys) {
        Write-Host "  Instalando Playwright para Python (solo la primera vez)..." -ForegroundColor Yellow
        & $py -m pip install --user --quiet playwright
        & $py -c "import playwright" 2>$null
        if ($LASTEXITCODE -eq 0) { return $py }
    }
    return $null
}

function Get-EdgeUserAgent {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    $major = '130'
    if ($edge) { $major = ((Get-Item $edge).VersionInfo.ProductVersion -split '\.')[0] }
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36 Edg/$major.0.0.0"
}

# ---------- Carpeta Descargas ----------
function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path $p)) { return $p }
    } catch {}
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# ---------- Detectar URLs abiertas en el navegador ----------
function Get-BrowserUrls {
    $urls = New-Object System.Collections.Generic.List[string]
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $procs = Get-Process -Name chrome, msedge, brave, opera, vivaldi, firefox -ErrorAction SilentlyContinue |
                 Where-Object { $_.MainWindowHandle -ne 0 }
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Edit)
        foreach ($p in $procs) {
            try {
                $root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
                $edit = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
                if (-not $edit) { continue }
                $val = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
                if ([string]::IsNullOrWhiteSpace($val)) { continue }
                if ($val -notmatch '^[a-z]+://') { $val = "https://$val" }
                if ($val -match '^https?://[^\s]+\.[^\s]+' -and -not $urls.Contains($val)) { $urls.Add($val) }
            } catch {}
        }
    } catch {}
    return $urls
}

function Get-ClipboardCapture {
    # Video copiado desde la extension de Chrome (JSON que empieza con {"dv":1)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $t = [System.Windows.Forms.Clipboard]::GetText()
        if ($t -and $t.TrimStart().StartsWith('{"dv":1')) { return ($t | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Install-ChromeExtension {
    $chrome = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
                                'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1).'(default)'
    Set-Clipboard -Value $ExtDir
    Write-Host ''
    Write-Host '  INSTALAR LA EXTENSION EN CHROME (una sola vez):' -ForegroundColor Cyan
    Write-Host '   1. En Chrome abri:  chrome://extensions' -ForegroundColor White
    Write-Host '   2. Activa "Modo de desarrollador" (arriba a la derecha).' -ForegroundColor White
    Write-Host '   3. Toca "Cargar extension sin empaquetar" y elegi esta carpeta' -ForegroundColor White
    Write-Host '      (ya esta copiada en el portapapeles, pegala con Ctrl+V):' -ForegroundColor White
    Write-Host "      $ExtDir" -ForegroundColor Green
    Write-Host '   4. Fija la extension con el icono de la pieza de rompecabezas.' -ForegroundColor White
    Write-Host ''
    Write-Host '  USO: dale PLAY al video en Chrome > toca el icono de la extension >' -ForegroundColor White
    Write-Host '       "Copiar para el descargador" > abri este descargador (opcion 1).' -ForegroundColor White
    if ($chrome -and (Test-Path $chrome)) { try { Start-Process $chrome 'chrome://extensions' } catch {} }
    Start-Process explorer.exe "`"$ExtDir`""
    Write-Host ''
    Read-Host '  Enter para volver al menu' | Out-Null
}

function Get-ClipboardUrl {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $t = [System.Windows.Forms.Clipboard]::GetText()
        if ($t -and $t.Trim() -match '^https?://\S+$') { return $t.Trim() }
    } catch {}
    return $null
}

# ---------- Formatos ----------
$Formatos = [ordered]@{
    '1' = @{ Nombre = 'Video MP4 - mejor calidad (recomendado)'; Args = @('-f', 'bv*+ba/b', '-S', 'res,ext:mp4:m4a', '--merge-output-format', 'mp4') }
    '2' = @{ Nombre = 'Video MP4 - hasta 1080p';                 Args = @('-f', 'bv*+ba/b', '-S', 'res:1080,ext:mp4:m4a', '--merge-output-format', 'mp4') }
    '3' = @{ Nombre = 'Video MP4 - hasta 720p';                  Args = @('-f', 'bv*+ba/b', '-S', 'res:720,ext:mp4:m4a', '--merge-output-format', 'mp4') }
    '4' = @{ Nombre = 'Video MP4 - hasta 480p (liviano)';        Args = @('-f', 'bv*+ba/b', '-S', 'res:480,ext:mp4:m4a', '--merge-output-format', 'mp4') }
    '5' = @{ Nombre = 'Video WEBM - mejor calidad';              Args = @('-f', 'bv*+ba/b', '-S', 'res,ext:webm:webm', '--merge-output-format', 'webm') }
    '6' = @{ Nombre = 'Video MKV - mejor calidad';               Args = @('-f', 'bv*+ba/b', '--merge-output-format', 'mkv') }
    '7' = @{ Nombre = 'Solo audio MP3';                          Args = @('-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '0') }
    '8' = @{ Nombre = 'Solo audio M4A';                          Args = @('-f', 'ba[ext=m4a]/ba/b', '-x', '--audio-format', 'm4a') }
    '9' = @{ Nombre = 'Ver todos los formatos y elegir codigo';  Args = $null }
}

# ---------- Ejecutar yt-dlp mostrando progreso y capturando errores ----------
function Quote-Arg([string]$a) {
    if ($a -match '[\s"&|<>^]' -or $a -eq '') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Invoke-YtDlp {
    param([string[]]$Arguments)
    $errFile = Join-Path $TmpDir 'stderr.txt'
    if (Test-Path $errFile) { Remove-Item $errFile -Force }
    $argLine = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    $p = Start-Process -FilePath $script:YtDlp -ArgumentList $argLine -NoNewWindow -Wait -PassThru -RedirectStandardError $errFile
    $stderr = @()
    if (Test-Path $errFile) { $stderr = @(Get-Content $errFile -Encoding UTF8) }
    return @{ Code = $p.ExitCode; Err = $stderr }
}

function Start-Download {
    # Descarga y muestra el resultado. Devuelve @{ Ok; Errores }
    param([string]$Url, [string[]]$FmtArgs, [string[]]$Extra, [string]$Template)
    $rutaFile = Join-Path $TmpDir 'ultimo.txt'
    if (Test-Path $rutaFile) { Remove-Item $rutaFile -Force }
    $ytArgs = $script:BaseArgs + $Extra + $FmtArgs + @(
        '-P', $script:Destino,
        '-o', $Template,
        '--print-to-file', 'after_move:filepath', $rutaFile,
        $Url)

    Write-Host ''
    Write-Host "  Descargando: $Url" -ForegroundColor Cyan
    Write-Host ''
    $res = Invoke-YtDlp -Arguments $ytArgs

    $avisos  = @($res.Err | Where-Object { $_ -match '^WARNING' })
    $errores = @($res.Err | Where-Object { $_ -notmatch '^WARNING' -and $_.Trim() })
    foreach ($w in $avisos) { Write-Host "  $w" -ForegroundColor Yellow }

    if ($res.Code -eq 0 -and (Test-Path $rutaFile)) {
        $archivo = (Get-Content $rutaFile -Encoding UTF8 | Select-Object -Last 1)
        Write-Host ''
        Write-Host '  LISTO. Guardado en:' -ForegroundColor Green
        Write-Host "  $archivo" -ForegroundColor Green
        Write-Host ''
        $o = Read-Default '  Abrir la carpeta? (s/N)' 'n'
        if ($o -match '^s') { Start-Process explorer.exe "/select,`"$archivo`"" }
        return @{ Ok = $true; Errores = @() }
    }
    if ($errores.Count -eq 0) { $errores = @("yt-dlp termino con codigo $($res.Code) sin mensaje de error.") }
    return @{ Ok = $false; Errores = $errores; Code = $res.Code }
}

function Get-Hint([string[]]$lines) {
    $t = ($lines -join ' ')
    switch -Regex ($t) {
        'DRM'                                   { return 'El video tiene proteccion DRM (Netflix, Disney+, Prime, etc.). No se puede descargar.' }
        'Unsupported URL|No video formats|Unable to extract' { return 'yt-dlp no reconoce el video en esa pagina. El MODO NAVEGADOR lo busca dentro del reproductor.' }
        'Sign in|login|logged|cookies|private'  { return 'El video pide iniciar sesion. Proba el MODO NAVEGADOR visible e inicia sesion en la ventana que se abre.' }
        'HTTP Error 403'                        { return 'El sitio bloqueo la descarga. Proba el MODO NAVEGADOR o actualizar yt-dlp (opcion "u").' }
        'HTTP Error 404'                        { return 'El video ya no existe o la direccion esta incompleta.' }
        'ffmpeg|ffprobe'                        { return 'Falta ffmpeg o fallo al unir audio y video. Proba con formato 6 (MKV).' }
        'Requested format is not available'     { return 'Ese formato no existe para este video. Elegi la opcion 1 o mira la lista con la opcion 9.' }
        'getaddrinfo|timed out|Connection'      { return 'Problema de conexion a internet. Revisa la red y volve a intentar.' }
        default                                 { return 'Proba el MODO NAVEGADOR o actualizar yt-dlp con la opcion "u" del menu.' }
    }
}

# ---------- MODO NAVEGADOR: buscar el video dentro de la pagina ----------
function Invoke-Sniffer {
    param([string]$Py, [string]$Url, [string]$Mode)
    $out = Join-Path $TmpDir 'busqueda.json'
    $cookies = Join-Path $TmpDir 'cookies.txt'
    Remove-Item $out, $cookies -Force -ErrorAction SilentlyContinue
    & $Py $SnifferPy $Url $out $Mode $ProfileDir $script:UA $cookies
    if (-not (Test-Path $out)) { return $null }
    $data = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
    $data | Add-Member -NotePropertyName cookies -NotePropertyValue $cookies -Force
    return $data
}

function Get-SafeName([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'video' }
    $s = ($s -replace '[\\/:*?"<>|\r\n\t]', ' ') -replace '\s+', ' '
    $s = $s.Trim(' .')
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120).Trim() }
    if (-not $s) { $s = 'video' }
    return $s
}

function Invoke-BrowserMode {
    param([string]$Url, [string[]]$FmtArgs)
    $py = Get-PythonPlaywright
    if (-not $py) {
        Show-Error -Titulo 'El modo navegador necesita Python con Playwright.' -Detalle @('No se encontro Python en esta PC.') -Sugerencia 'Instala Python con: winget install Python.Python.3.12  y volve a abrir el descargador.'
        return
    }

    Write-Host ''
    Write-Host '  MODO NAVEGADOR: abriendo la pagina en Edge (invisible) y dandole play...' -ForegroundColor Cyan
    Write-Host '  Esto tarda hasta 30 segundos.' -ForegroundColor DarkGray
    $data = Invoke-Sniffer -Py $py -Url $Url -Mode 'headless'

    if (-not $data -or @($data.candidates).Count -eq 0) {
        Write-Host ''
        Write-Host '  No encontre el video automaticamente (puede pedir login o un clic).' -ForegroundColor Yellow
        $v = Read-Default '  Abrir Edge visible para que lo reproduzcas vos? (S/n)' 's'
        if ($v -notmatch '^s') { return }
        Write-Host ''
        Write-Host '  1. Se abre una ventana de Edge con la pagina.' -ForegroundColor White
        Write-Host '  2. Si pide, inicia sesion (queda guardada para la proxima).' -ForegroundColor White
        Write-Host '  3. Dale PLAY al video y deja que corra unos segundos.' -ForegroundColor White
        Write-Host '  4. CERRA la ventana de Edge para continuar.' -ForegroundColor White
        $data = Invoke-Sniffer -Py $py -Url $Url -Mode 'visible'
    }

    $cands = @()
    if ($data) { $cands = @($data.candidates) }
    if ($cands.Count -eq 0) {
        Show-Error -Titulo 'No se encontro ningun video dentro de la pagina.' -Detalle @("URL: $Url") -Sugerencia 'Si el video se reproduce pero no aparece, probablemente tiene proteccion DRM y no se puede descargar.'
        return
    }

    Write-Host ''
    Write-Host '  Videos encontrados en la pagina:' -ForegroundColor White
    $tipos = @{ hls = 'Stream HLS'; dash = 'Stream DASH'; file = 'Archivo'; embed = 'Reproductor' }
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $tam = if ($c.size -gt 0) { '{0:N1} MB' -f ($c.size / 1MB) } else { '' }
        $tipo = $tipos[$c.kind]
        if ($c.master) { $tipo += ' (todas las calidades)' }
        $u = $c.url; if ($u.Length -gt 90) { $u = $u.Substring(0, 87) + '...' }
        Write-Host ("   {0}) {1} {2}" -f ($i + 1), $tipo, $tam) -ForegroundColor White
        Write-Host ("      {0}" -f $u) -ForegroundColor DarkGray
    }
    Write-Host '   Si hay varios, el primero suele ser el bueno (los cortos pueden ser publicidad).' -ForegroundColor DarkGray
    $maxTecla = [math]::Min($cands.Count, 9)
    $n = Read-Timeout -Prompt '  Cual descargo?' -Default '1' -Seconds 5 -Valid (1..$maxTecla | ForEach-Object { "$_" }) -Opciones "1-$maxTecla"
    if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $cands.Count) { $n = '1' }
    $c = $cands[[int]$n - 1]
    Start-CapturedDownload -Url $c.url -Kind $c.kind -Page $data.page -Title $data.title -Ua $script:UA -CookiesFile $data.cookies -FmtArgs $FmtArgs
}

function Start-CapturedDownload {
    # Descarga una direccion de video capturada (modo navegador o extension de Chrome)
    param([string]$Url, [string]$Kind, [string]$Page, [string]$Title, [string]$Ua, [string]$CookiesFile, [string[]]$FmtArgs)
    $extra = @('--referer', $Page, '--user-agent', $Ua, '--concurrent-fragments', '4')
    if ($CookiesFile -and (Test-Path $CookiesFile) -and (Get-Item $CookiesFile).Length -gt 40) { $extra += @('--cookies', $CookiesFile) }

    if ($Kind -eq 'embed') {
        $template = '%(title).150B [%(id)s].%(ext)s'
    } else {
        $nombre = Get-SafeName $Title
        if (Get-ChildItem -LiteralPath $script:Destino -Filter "$nombre.*" -ErrorAction SilentlyContinue) {
            $nombre = "$nombre - $(Get-Date -Format 'yyyyMMdd-HHmmss')"
        }
        $template = ($nombre -replace '%', '%%') + '.%(ext)s'
    }

    $r = Start-Download -Url $Url -FmtArgs $FmtArgs -Extra $extra -Template $template
    if (-not $r.Ok) {
        Show-Error -Titulo "No se pudo descargar el video encontrado (codigo $($r.Code))." -Detalle (@("Video: $Url") + $r.Errores) -Sugerencia ((Get-Hint $r.Errores) -replace 'Proba el MODO NAVEGADOR o ', 'Proba otro de la lista o ')
    }
}

# =========================== PROGRAMA PRINCIPAL ===========================
try {
    Show-Title

    $script:YtDlp = Get-Tool 'yt-dlp'
    if (-not $script:YtDlp) { $script:YtDlp = Install-YtDlp }
    $Ffmpeg = Get-Tool 'ffmpeg'
    if (-not $Ffmpeg) { $Ffmpeg = Install-Ffmpeg }
    $FfmpegDir = Split-Path $Ffmpeg -Parent

    $script:Destino = Get-DownloadsFolder
    $script:UA = Get-EdgeUserAgent
    $CookiesBrowser = $null

    while ($true) {
        Show-Title
        Write-Host "  Carpeta de destino: $script:Destino" -ForegroundColor DarkGray
        if ($CookiesBrowser) { Write-Host "  Usando cookies de: $CookiesBrowser" -ForegroundColor DarkGray }
        Write-Host ''

        # ---- 1. Elegir URL ----
        Write-Host '  Buscando videos abiertos en el navegador...' -ForegroundColor DarkGray
        $candidatas = New-Object System.Collections.Generic.List[string]
        $cap = Get-ClipboardCapture
        if ($cap) { $candidatas.Add('CAPTURA') }
        $clip = Get-ClipboardUrl
        if ($clip) { $candidatas.Add($clip) }
        foreach ($u in (Get-BrowserUrls)) { if (-not $candidatas.Contains($u)) { $candidatas.Add($u) } }

        Write-Host ''
        Write-Host '  [ PASO 1 ] Que video queres descargar?' -ForegroundColor White
        $tiposCap = @{ hls = 'stream HLS'; dash = 'stream DASH'; file = 'archivo de video' }
        for ($i = 0; $i -lt $candidatas.Count; $i++) {
            if ($candidatas[$i] -eq 'CAPTURA') {
                Write-Host ("   {0}) [Chrome] {1} - {2} (copiado con la extension)" -f ($i + 1), $cap.title, $tiposCap[$cap.kind]) -ForegroundColor Green
                continue
            }
            $origen = if ($candidatas[$i] -eq $clip) { '(portapapeles)' } else { '(pestana abierta)' }
            Write-Host ("   {0}) {1} {2}" -f ($i + 1), $candidatas[$i], $origen)
        }
        if ($candidatas.Count -eq 0) { Write-Host '   No detecte ninguna pestana. Pega la direccion del video.' -ForegroundColor DarkGray }
        Write-Host '   Agrega una "b" al numero (ej: 1b) para ir directo al MODO NAVEGADOR.' -ForegroundColor DarkGray
        Write-Host '   x) Instalar la extension de Chrome (usa tu sesion de Chrome)' -ForegroundColor DarkGray
        Write-Host '   c) Usar cookies del navegador (videos que piden iniciar sesion)' -ForegroundColor DarkGray
        Write-Host '   u) Actualizar yt-dlp     s) Salir' -ForegroundColor DarkGray
        Write-Host ''
        $def = if ($candidatas.Count -gt 0) { '1' } else { '' }
        $sel = Read-Default '  Numero o URL pegada (Enter = 1)' $def

        if ($sel -eq 's') { break }
        if ($sel -eq 'x') { Install-ChromeExtension; continue }
        if ($sel -eq 'u') {
            Write-Host ''
            & $script:YtDlp -U
            if ($LASTEXITCODE -ne 0) { Write-Host '  Si yt-dlp se instalo con winget, actualizalo con: winget upgrade yt-dlp' -ForegroundColor Yellow }
            Read-Host '  Enter para continuar' | Out-Null
            continue
        }
        if ($sel -eq 'c') {
            Write-Host '   Navegador: 1) firefox  2) edge  3) chrome  4) brave  0) ninguno' -ForegroundColor White
            $b = Read-Default '   Opcion (Enter = 1)' '1'
            $CookiesBrowser = @{ '1' = 'firefox'; '2' = 'edge'; '3' = 'chrome'; '4' = 'brave'; '0' = $null }[$b]
            if ($CookiesBrowser -in 'chrome', 'edge', 'brave') {
                Write-Host '   Aviso: con Chrome/Edge/Brave hay que CERRAR el navegador antes de descargar, y aun asi puede fallar. Firefox es lo mas confiable.' -ForegroundColor Yellow
                Read-Host '   Enter para continuar' | Out-Null
            }
            continue
        }

        $directoNavegador = $false
        if ($sel -match '^(\d+)b$') { $directoNavegador = $true; $sel = $Matches[1] }

        $url = $null
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $candidatas.Count) { $url = $candidatas[[int]$sel - 1] }
        elseif ($sel -match '^https?://\S+$') { $url = $sel }
        else {
            Show-Error -Titulo 'La entrada no es un numero de la lista ni una URL valida.' -Detalle @("Valor recibido: '$sel'") -Sugerencia 'Copia la direccion del video desde la barra del navegador (empieza con https://).'
            Read-Host '  Enter para volver' | Out-Null
            continue
        }

        $esCaptura = ($url -eq 'CAPTURA')
        if ($esCaptura) {
            $url = $cap.url
            $cookiesChrome = Join-Path $TmpDir 'cookies-chrome.txt'
            [IO.File]::WriteAllText($cookiesChrome, [string]$cap.cookies, (New-Object Text.UTF8Encoding($false)))
        }

        # ---- 2. Elegir formato ----
        Write-Host ''
        Write-Host '  [ PASO 2 ] En que formato?' -ForegroundColor White
        foreach ($k in $Formatos.Keys) { Write-Host "   $k) $($Formatos[$k].Nombre)" }
        Write-Host ''
        $f = Read-Default '  Opcion (Enter = 1)' '1'
        if (-not $Formatos.Contains($f)) { $f = '1' }

        $script:BaseArgs = @('--no-playlist', '--no-mtime', '--ffmpeg-location', $FfmpegDir, '--windows-filenames')
        $extraCookies = @()
        if ($CookiesBrowser) { $extraCookies = @('--cookies-from-browser', $CookiesBrowser) }
        if ($esCaptura) { $extraCookies = @('--referer', $cap.page, '--user-agent', $cap.ua, '--cookies', $cookiesChrome) }

        if ($f -eq '9') {
            Write-Host ''
            & $script:YtDlp @script:BaseArgs @extraCookies -F $url
            Write-Host ''
            Write-Host '  Escribi el ID de la columna izquierda. Para unir video+audio: 137+140' -ForegroundColor DarkGray
            $code = Read-Default '  Codigo de formato (Enter = mejor)' 'bv*+ba/b'
            $fmtArgs = @('-f', $code, '--merge-output-format', 'mkv')
        } else {
            $fmtArgs = $Formatos[$f].Args
        }

        # ---- 3. Descargar ----
        if ($esCaptura) {
            Start-CapturedDownload -Url $url -Kind $cap.kind -Page $cap.page -Title $cap.title -Ua $cap.ua -CookiesFile $cookiesChrome -FmtArgs $fmtArgs
        } elseif ($directoNavegador) {
            Invoke-BrowserMode -Url $url -FmtArgs $fmtArgs
        } else {
            $r = Start-Download -Url $url -FmtArgs $fmtArgs -Extra $extraCookies -Template '%(title).150B [%(id)s].%(ext)s'
            if (-not $r.Ok) {
                $hint = Get-Hint $r.Errores
                Show-Error -Titulo "No se pudo descargar el video (codigo de salida $($r.Code))." -Detalle (@("URL: $url") + $r.Errores) -Sugerencia $hint
                $sinArreglo = ($r.Errores -join ' ') -match 'DRM|HTTP Error 404|getaddrinfo|timed out'
                if (-not $sinArreglo) {
                    $m = Read-Timeout -Prompt '  Probar el MODO NAVEGADOR (busca el video dentro de la pagina)?' -Default 's' -Seconds 5
                    if ($m -match '^s') { Invoke-BrowserMode -Url $url -FmtArgs $fmtArgs }
                }
            }
        }

        Write-Host ''
        $otra = Read-Default '  Descargar otro video? (S/n)' 's'
        if ($otra -notmatch '^s') { break }
    }
}
catch {
    Write-Host ''
    Write-Host ($_ | Out-String) -ForegroundColor Red -BackgroundColor Black
    Show-Error -Titulo 'Error inesperado del descargador.' -Detalle @($_.Exception.Message) -Sugerencia 'Revisa tu conexion a internet. Si el error sigue, saca una captura de esta pantalla.'
    Read-Host '  Enter para cerrar' | Out-Null
    exit 1
}
