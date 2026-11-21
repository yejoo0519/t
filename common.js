// 두 페이지가 같이 쓰는 도우미
window.K = (() => {
  const cfg = window.KUJI_CONFIG || {};
  const ready = !!(cfg.url && cfg.anonKey && window.supabase);
  const sb = ready ? window.supabase.createClient(cfg.url, cfg.anonKey) : null;
  const $ = id => document.getElementById(id);
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const COLORS = ['#e2312f','#f08a1c','#d4a200','#2f9e5a','#1f7ae0','#7a4fd6','#d1428f','#4a5560'];
  const badge = (g, c) => `<div class="badge ${String(g).length > 2 ? 'sm' : ''}" style="background:${esc(c)}">${esc(g)}</div>`;
  const photoUrl = path => sb.storage.from('proofs').getPublicUrl(path).data.publicUrl;
  let tt;
  const toast = t => { const e = $('toast'); e.textContent = t; e.hidden = false; clearTimeout(tt); tt = setTimeout(() => e.hidden = true, 2800); };
  const errMsg = e => (e && (e.message || e.error_description)) || '알 수 없는 오류';
  const fmtTime = ts => { const d = new Date(ts); return `${d.getMonth()+1}/${d.getDate()} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`; };
  return { sb, ready, $, esc, COLORS, badge, photoUrl, toast, errMsg, fmtTime };
})();
