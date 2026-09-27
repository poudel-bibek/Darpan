// Links come from where the site is served, https://<owner>.github.io/<repo>/, so no account name is written
// into the repository. For a local preview, ?repo=<owner>/<repo> says which one.
(() => {
  const q = new URLSearchParams(location.search).get('repo');
  const host = location.hostname, first = location.pathname.split('/').filter(Boolean)[0] || '';
  let repo = q && /^[\w.-]+\/[\w.-]+$/.test(q) ? q : null;
  if (!repo && host.endsWith('.github.io') && first && !first.endsWith('.html'))
    repo = host.slice(0, -'.github.io'.length) + '/' + first;
  const gh = repo ? 'https://github.com/' + repo : null;

  if (gh) {
    for (const a of document.querySelectorAll('[data-asset]')) a.href = gh + '/releases/latest/download/' + a.dataset.asset;
    for (const a of document.querySelectorAll('[data-gh]')) a.href = gh + a.dataset.gh;
  }
  for (const a of document.querySelectorAll('[data-home]')) a.href = location.origin + '/';   // the owner's site

  const list = document.getElementById('releases');
  if (!list) return;
  const fail = () => {
    list.textContent = '';
    const p = document.createElement('p');
    p.className = 'fine';
    p.append("The changelog couldn't load. ");
    if (gh) {
      const a = document.createElement('a');
      a.href = gh + '/releases';
      a.textContent = 'See the releases on GitHub.';
      p.append(a);
    }
    list.append(p);
  };
  if (!repo) return fail();
  // GitHub renders each release's notes to sanitised HTML (body_html), so no Markdown library is needed.
  fetch('https://api.github.com/repos/' + repo + '/releases?per_page=50', {headers: {Accept: 'application/vnd.github.html+json'}})
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((releases) => {
      list.textContent = '';
      for (const r of releases.filter((r) => !r.draft)) {
        const art = document.createElement('article');
        const h = document.createElement('h2');
        h.textContent = r.name || r.tag_name;
        const meta = document.createElement('p');
        meta.className = 'fine';
        const when = new Date(r.published_at);
        meta.textContent = when.toLocaleDateString(undefined, {year: 'numeric', month: 'long', day: 'numeric'}) + ' · ';
        const dl = document.createElement('a');
        if (String(r.html_url).startsWith('https://github.com/')) dl.href = r.html_url;
        dl.textContent = 'Downloads';
        meta.append(dl);
        const notes = document.createElement('div');
        notes.className = 'notes';
        notes.innerHTML = r.body_html || '';
        art.append(h, meta, notes);
        list.append(art);
      }
      if (!list.children.length) fail();
    })
    .catch(fail);
})();
