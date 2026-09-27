// The changelog: each release's notes. GitHub renders them to sanitised HTML (body_html), so no Markdown
// library is needed.
(() => {
  const list = document.getElementById('releases');
  const fail = () => {
    list.textContent = '';
    const p = document.createElement('p');
    p.className = 'fine';
    p.append("The changelog couldn't load. ");
    const a = document.createElement('a');
    a.href = 'https://github.com/poudel-bibek/Darpan/releases';
    a.textContent = 'See the releases on GitHub.';
    p.append(a);
    list.append(p);
  };
  fetch('https://api.github.com/repos/poudel-bibek/Darpan/releases?per_page=50', {headers: {Accept: 'application/vnd.github.html+json'}})
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((releases) => {
      list.textContent = '';
      for (const r of releases) {
        const art = document.createElement('article');
        const h = document.createElement('h2');
        h.textContent = r.name || r.tag_name;
        const meta = document.createElement('p');
        meta.className = 'fine';
        meta.textContent = new Date(r.published_at).toLocaleDateString(undefined, {year: 'numeric', month: 'long', day: 'numeric'}) + ' · ';
        const dl = document.createElement('a');
        dl.href = r.html_url;
        dl.textContent = 'Downloads';
        meta.append(dl);
        const notes = document.createElement('div');
        notes.className = 'notes';
        notes.innerHTML = r.body_html || '';
        art.append(h, meta, notes);
        list.append(art);
      }
    })
    .catch(fail);
})();
