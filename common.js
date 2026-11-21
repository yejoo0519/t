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
  // 드래곤 이름 → 도감 프로필 이미지 (dragons.json = dogam 저장소 dragons.js 에서 뽑은 목록)
  const IMG_BASE = 'https://raw.githubusercontent.com/yejoo0519/dogam/refs/heads/main';
  const norm = s => String(s || '').replace(/\s+/g, '').replace(/드래곤$/, '').toLowerCase();
  let dragons = null;
  async function loadDragons() {
    if (dragons) return dragons;
    try {
      const arr = await (await fetch('dragons.json')).json();
      const map = new Map();
      for (const [id, ko, al, n] of arr) {
        const e = {id, name: ko, url: `${IMG_BASE}/dragon/${id}/profile/${n}.png`};
        for (const k of [ko, ...al]) { const key = norm(k); if (key && !map.has(key)) map.set(key, e); }
      }
      dragons = {arr, map, keys: [...map.keys()].sort((a, b) => b.length - a.length)};
    } catch (e) { dragons = {arr: [], map: new Map(), keys: []}; }
    return dragons;
  }
  // 정확히 같은 이름/별칭 → 없으면 상품명 안에 들어있는 가장 긴 드래곤 이름 (예: "고대신룡 1마리")
  function findDragon(name) {
    if (!dragons) return null;
    const n = norm(name);
    if (!n) return null;
    if (dragons.map.has(n)) return dragons.map.get(n);
    const k = dragons.keys.find(k => k.length >= 2 && n.includes(k));
    return k ? dragons.map.get(k) : null;
  }
  // 상품 그림: 이미지 있으면 드래곤 얼굴 + 등급 딱지, 없으면 등급 배지
  const art = (g, c, img) => img
    ? `<div class="art"><img src="${esc(img)}" alt="" loading="lazy"><span class="g" style="background:${esc(c)}">${esc(g)}</span></div>`
    : badge(g, c);

  return { sb, ready, $, esc, COLORS, badge, art, photoUrl, toast, errMsg, fmtTime, loadDragons, findDragon };
})();
