const API_URL = '/api';
let isAuthenticated = false;
let authToken = '';
let messageTimer = null;

function apiFetch(url, options = {}) {
    const headers = new Headers(options.headers || {});
    if (authToken) headers.set('Authorization', `Bearer ${authToken}`);
    return fetch(url, { credentials: 'include', ...options, headers });
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text ?? '';
    return div.innerHTML;
}

function showTab(btn, tabName) {
    if (!isAuthenticated) return;
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById(`${tabName}-tab`).classList.add('active');

    if (tabName === 'companies') { document.getElementById('company-search').value = ''; loadCompanies(); }
    else if (tabName === 'individuals') { document.getElementById('individual-search').value = ''; loadIndividuals(); loadCompaniesForDropdown(); }
    else if (tabName === 'building-info') loadBuildingInfo();
    else if (tabName === 'appearance') loadBackgroundImage();
    else if (tabName === 'deploy') loadDeployTab();
}

function showMessage(text, type = 'success', options = {}) {
    const persistent = !!options.persistent;
    const msg = document.getElementById('message');
    if (messageTimer) {
        clearTimeout(messageTimer);
        messageTimer = null;
    }
    msg.innerHTML = '';
    const textEl = document.createElement('span');
    textEl.className = 'message-text';
    textEl.textContent = text;
    msg.appendChild(textEl);
    if (persistent) {
        const okBtn = document.createElement('button');
        okBtn.type = 'button';
        okBtn.className = 'message-ok-btn';
        okBtn.textContent = 'OK';
        okBtn.addEventListener('click', () => msg.classList.remove('active'));
        msg.appendChild(okBtn);
    }
    msg.className = `message ${type} active`;
    if (!persistent) {
        messageTimer = setTimeout(() => {
            msg.classList.remove('active');
            messageTimer = null;
        }, 5000);
    }
}

async function downloadCsv(kind) {
    try {
        const res = await apiFetch(`${API_URL}/${kind}/csv`);
        if (!res.ok) {
            let message = `HTTP ${res.status}`;
            try {
                const data = await res.json();
                if (data && data.error) message = data.error;
            } catch (e) {}
            throw new Error(message);
        }

        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `${kind}.csv`;
        document.body.appendChild(a);
        a.click();
        a.remove();
        URL.revokeObjectURL(url);
        const exportedRows = res.headers.get('X-CSV-Exported-Rows') || '0';
        const status = res.headers.get('X-CSV-Status') || 'ok';
        showMessage(`Downloaded ${kind}.csv (status: ${status}, rows: ${exportedRows})`);
    } catch (error) {
        showMessage(`Download failed: ${error.message}`, 'error');
    }
}

async function downloadBackup() {
    try {
        const res = await apiFetch(`${API_URL}/backup.txt`);
        if (!res.ok) {
            let message = `HTTP ${res.status}`;
            try {
                const data = await res.json();
                if (data && data.error) message = data.error;
            } catch (e) {}
            throw new Error(message);
        }

        const blob = await res.blob();
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = 'directory-backup.txt';
        document.body.appendChild(a);
        a.click();
        a.remove();
        URL.revokeObjectURL(url);
        showMessage('Text backup downloaded');
    } catch (error) {
        showMessage(`Text backup download failed: ${error.message}`, 'error', { persistent: true });
    }
}

function renderCompanies(companies) {
    document.getElementById('companies-list').innerHTML = companies.map(c => `
        <tr>
            <td>${escapeHtml(c.name)}</td><td>${escapeHtml(c.building)}</td><td>${escapeHtml(c.suite)}</td>
            <td>${escapeHtml(c.floor) || '-'}</td><td>${escapeHtml(c.phone) || '-'}</td>
            <td class="actions">
                <button class="btn btn-primary" onclick="editCompany(${c.id})">Edit</button>
                <button class="btn btn-danger" onclick="deleteCompany(${c.id})">Delete</button>
            </td>
        </tr>
    `).join('');
}

async function loadCompanies() {
    try {
        renderCompanies(await apiFetch(`${API_URL}/companies`).then(r => r.json()));
    } catch (error) { showMessage('Failed to load companies', 'error'); }
}

let _companySearchTimer;
function searchCompanies(q) {
    clearTimeout(_companySearchTimer);
    _companySearchTimer = setTimeout(async () => {
        try {
            const url = q.trim()
                ? `${API_URL}/companies/search?q=${encodeURIComponent(q)}`
                : `${API_URL}/companies`;
            renderCompanies(await apiFetch(url).then(r => r.json()));
        } catch (e) { showMessage('Search failed', 'error'); }
    }, 300);
}

function editCompany(id) {
    apiFetch(`${API_URL}/companies`).then(r => r.json()).then(companies => {
        const company = companies.find(c => c.id === id);
        if (company) {
            document.getElementById('company-id').value = company.id;
            document.getElementById('company-name').value = company.name;
            document.getElementById('company-building').value = company.building;
            document.getElementById('company-suite').value = company.suite;
            document.getElementById('company-floor').value = company.floor || '';
            document.getElementById('company-phone').value = company.phone || '';
            window.scrollTo(0, 0);
        }
    });
}

async function deleteCompany(id) {
    try {
        const individuals = await apiFetch(`${API_URL}/individuals`).then(r => r.json());
        const linked = individuals.filter(p => p.company_id === id);
        const warning = linked.length > 0
            ? `\n\nWarning: ${linked.length} individual(s) are assigned to this company and will be left without a company.`
            : '';
        if (!confirm(`Delete this company?${warning}`)) return;
        const res = await apiFetch(`${API_URL}/companies/${id}`, { method: 'DELETE' });
        if (!res.ok) throw new Error(res.status);
        showMessage('Company deleted'); loadCompanies();
    } catch (error) { showMessage('Failed to delete', 'error'); }
}

function resetCompanyForm() {
    document.getElementById('company-form').reset();
    document.getElementById('company-id').value = '';
}

document.getElementById('company-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('company-id').value;
    const data = {
        name: document.getElementById('company-name').value,
        building: document.getElementById('company-building').value,
        suite: document.getElementById('company-suite').value,
        floor: document.getElementById('company-floor').value,
        phone: document.getElementById('company-phone').value
    };
    try {
        const res = await apiFetch(id ? `${API_URL}/companies/${id}` : `${API_URL}/companies`, {
            method: id ? 'PUT' : 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        if (!res.ok) throw new Error(res.status);
        showMessage(`Company ${id ? 'updated' : 'created'}`);
        resetCompanyForm(); loadCompanies();
    } catch (error) { showMessage('Failed to save', 'error'); }
});

document.getElementById('company-csv-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const file = document.getElementById('company-csv-file').files[0];
    if (!file) return;
    if (!confirm('Upload companies CSV and replace all current companies?')) return;

    const formData = new FormData();
    formData.append('file', file);
    try {
        const res = await apiFetch(`${API_URL}/companies/csv`, { method: 'POST', body: formData, credentials: 'include' });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        document.getElementById('company-csv-file').value = '';
        const dbCount = data.db_counts && typeof data.db_counts.companies === 'number'
            ? data.db_counts.companies
            : 'unknown';
        showMessage(`Companies CSV imported (${data.imported || 0} rows). DB companies count: ${dbCount}`, 'success', { persistent: true });
        loadCompanies();
        loadCompaniesForDropdown();
    } catch (error) {
        showMessage(`Companies CSV import failed: ${error.message}`, 'error', { persistent: true });
    }
});

function renderIndividuals(individuals) {
    document.getElementById('individuals-list').innerHTML = individuals.map(p => `
        <tr>
            <td>${escapeHtml(p.last_name)}, ${escapeHtml(p.first_name)}</td><td>${escapeHtml(p.title) || '-'}</td>
            <td>${escapeHtml(p.building)}</td><td>${escapeHtml(p.suite)}</td><td>${escapeHtml(p.phone) || '-'}</td>
            <td class="actions">
                <button class="btn btn-primary" onclick="editIndividual(${p.id})">Edit</button>
                <button class="btn btn-danger" onclick="deleteIndividual(${p.id})">Delete</button>
            </td>
        </tr>
    `).join('');
}

async function loadIndividuals() {
    try {
        renderIndividuals(await apiFetch(`${API_URL}/individuals`).then(r => r.json()));
    } catch (error) { showMessage('Failed to load individuals', 'error'); }
}

let _individualSearchTimer;
function searchIndividuals(q) {
    clearTimeout(_individualSearchTimer);
    _individualSearchTimer = setTimeout(async () => {
        try {
            const url = q.trim()
                ? `${API_URL}/individuals/search?q=${encodeURIComponent(q)}`
                : `${API_URL}/individuals`;
            renderIndividuals(await apiFetch(url).then(r => r.json()));
        } catch (e) { showMessage('Search failed', 'error'); }
    }, 300);
}

async function loadCompaniesForDropdown() {
    try {
        const response = await apiFetch(`${API_URL}/companies`);
        const companies = await response.json();
        document.getElementById('individual-company').innerHTML =
            '<option value="">-- None --</option>' +
            companies.map(c => `<option value="${c.id}">${escapeHtml(c.name)}</option>`).join('');
    } catch (error) { console.error('Failed to load companies'); }
}

function editIndividual(id) {
    apiFetch(`${API_URL}/individuals`).then(r => r.json()).then(individuals => {
        const person = individuals.find(p => p.id === id);
        if (person) {
            document.getElementById('individual-id').value = person.id;
            document.getElementById('individual-first-name').value = person.first_name;
            document.getElementById('individual-last-name').value = person.last_name;
            document.getElementById('individual-title').value = person.title || '';
            document.getElementById('individual-company').value = person.company_id || '';
            document.getElementById('individual-building').value = person.building;
            document.getElementById('individual-suite').value = person.suite;
            document.getElementById('individual-phone').value = person.phone || '';
            window.scrollTo(0, 0);
        }
    });
}

async function deleteIndividual(id) {
    if (!confirm('Delete this individual?')) return;
    try {
        await apiFetch(`${API_URL}/individuals/${id}`, { method: 'DELETE' });
        showMessage('Individual deleted'); loadIndividuals();
    } catch (error) { showMessage('Failed to delete', 'error'); }
}

function resetIndividualForm() {
    document.getElementById('individual-form').reset();
    document.getElementById('individual-id').value = '';
}

document.getElementById('individual-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('individual-id').value;
    const data = {
        first_name: document.getElementById('individual-first-name').value,
        last_name: document.getElementById('individual-last-name').value,
        title: document.getElementById('individual-title').value,
        company_id: document.getElementById('individual-company').value || null,
        building: document.getElementById('individual-building').value,
        suite: document.getElementById('individual-suite').value,
        phone: document.getElementById('individual-phone').value
    };
    try {
        const res = await apiFetch(id ? `${API_URL}/individuals/${id}` : `${API_URL}/individuals`, {
            method: id ? 'PUT' : 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        if (!res.ok) throw new Error(res.status);
        showMessage(`Individual ${id ? 'updated' : 'created'}`);
        resetIndividualForm(); loadIndividuals();
    } catch (error) { showMessage('Failed to save', 'error'); }
});

document.getElementById('individual-csv-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const file = document.getElementById('individual-csv-file').files[0];
    if (!file) return;
    if (!confirm('Upload individuals CSV and replace all current individuals?')) return;

    const formData = new FormData();
    formData.append('file', file);
    try {
        const res = await apiFetch(`${API_URL}/individuals/csv`, { method: 'POST', body: formData, credentials: 'include' });
        const data = await res.json();
        if (!res.ok) {
            const st = data.status
                ? ` [upload:${data.status.upload}, parse:${data.status.parse}, db:${data.status.db}]`
                : '';
            const cnt = data.db_counts && typeof data.db_counts.individuals === 'number'
                ? ` [db individuals:${data.db_counts.individuals}]`
                : '';
            throw new Error((data.error || `HTTP ${res.status}`) + st + cnt);
        }
        document.getElementById('individual-csv-file').value = '';
        const dbCount = data.db_counts && typeof data.db_counts.individuals === 'number'
            ? data.db_counts.individuals
            : 'unknown';
        const statusText = data.status
            ? ` upload:${data.status.upload}, parse:${data.status.parse}, db:${data.status.db}`
            : ' upload:ok, parse:ok, db:ok';
        showMessage(
            `Individuals CSV imported (${data.imported || 0} rows; uploaded:${data.uploaded_rows ?? 'n/a'}; parsed:${data.parsed_rows ?? 'n/a'}). ` +
            `DB individuals count: ${dbCount}. Status:${statusText}`,
            'success',
            { persistent: true }
        );
        loadIndividuals();
    } catch (error) {
        showMessage(`Individuals CSV import failed: ${error.message}`, 'error', { persistent: true });
    }
});

async function loadBuildingInfo() {
    try {
        const response = await apiFetch(`${API_URL}/building-info`);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const payload = await response.json();
        const content = typeof payload === 'string'
            ? payload
            : (payload && typeof payload.content === 'string' ? payload.content : '');
        document.getElementById('building-info-content').value = content;
    } catch (error) { showMessage('Failed to load', 'error'); }
}

document.getElementById('building-info-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
        await apiFetch(`${API_URL}/building-info`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ content: document.getElementById('building-info-content').value })
        });
        showMessage('Building information updated');
    } catch (error) { showMessage('Failed to update', 'error'); }
});

async function loadBackgroundImage() {
    try {
        const [activeRes, galleryRes] = await Promise.all([
            apiFetch(`${API_URL}/background-image`),
            apiFetch(`${API_URL}/background-images`)
        ]);
        const { filename: activeFilename } = await activeRes.json();
        const images = await galleryRes.json();
        renderBgGallery(images, activeFilename);
    } catch (error) { showMessage('Failed to load background images', 'error'); }
}

function renderBgGallery(images, activeFilename) {
    const gallery = document.getElementById('bg-gallery');
    if (!images.length) {
        gallery.innerHTML = '<p style="color:#999;">No images available.</p>';
        return;
    }
    gallery.innerHTML = images.map(img => {
        const dbKey = img.builtin ? img.filename : `uploads/${img.filename}`;
        const isActive = dbKey === activeFilename;
        const escapedDbKey = escapeHtml(dbKey);
        const escapedFilename = escapeHtml(img.filename);
        const escapedUrl = escapeHtml(img.url);
        return `
            <div class="bg-thumb${isActive ? ' active-bg' : ''}" onclick="selectBgImage('${escapedDbKey}')">
                ${isActive ? '<span class="bg-active-badge">Active</span>' : ''}
                <img src="${escapedUrl}" alt="${escapedFilename}" loading="lazy">
                <div class="bg-thumb-info">
                    <div class="bg-thumb-name">${escapedFilename}</div>
                    <div class="bg-thumb-actions">
                        ${img.builtin
                            ? '<span style="font-size:11px;color:#999;">Built-in</span>'
                            : `<button class="btn btn-danger" style="padding:4px 10px;font-size:12px;" onclick="event.stopPropagation();deleteBgImage('${escapedFilename}')">Delete</button>`
                        }
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

async function selectBgImage(dbKey) {
    try {
        const res = await apiFetch(`${API_URL}/background-image`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ filename: dbKey })
        });
        if (!res.ok) throw new Error(res.status);
        showMessage('Background image updated');
        loadBackgroundImage();
    } catch (error) { showMessage('Failed to set background image', 'error'); }
}

async function deleteBgImage(filename) {
    if (!confirm(`Delete image "${filename}"? This cannot be undone.`)) return;
    try {
        const res = await apiFetch(`${API_URL}/background-images/${encodeURIComponent(filename)}`, { method: 'DELETE' });
        if (!res.ok) throw new Error(res.status);
        showMessage('Image deleted');
        loadBackgroundImage();
    } catch (error) { showMessage('Failed to delete image', 'error'); }
}

document.getElementById('background-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const file = document.getElementById('bg-file').files[0];
    if (!file) return;
    const formData = new FormData();
    formData.append('image', file);
    try {
        const res = await apiFetch(`${API_URL}/background-image`, { method: 'POST', body: formData });
        if (!res.ok) {
            let message = `HTTP ${res.status}`;
            try {
                const data = await res.json();
                if (data && data.error) message = data.error;
            } catch (e) {}
            throw new Error(message);
        }
        showMessage('Image uploaded and set as background');
        document.getElementById('bg-file').value = '';
        loadBackgroundImage();
    } catch (error) { showMessage(`Failed to upload image: ${error.message}`, 'error', { persistent: true }); }
});

async function loadDeployTab() {
    try {
        const [kioskRes, urlRes, keyRes, revRes] = await Promise.all([
            apiFetch(`${API_URL}/kiosks`),
            apiFetch(`${API_URL}/kiosks/server-url`),
            apiFetch(`${API_URL}/kiosks/deploy-pubkey`),
            apiFetch(`${API_URL}/revision`)
        ]);
        const kiosks = await kioskRes.json();
        const { url, standbyUrl } = await urlRes.json();
        const keyData = await keyRes.json();
        const revisionData = await revRes.json();

        document.getElementById('deploy-server-url').textContent = url;
        document.getElementById('deploy-server-url-standby').textContent = standbyUrl || 'not configured';
        document.getElementById('deploy-revision').textContent = revisionData.revision || 'unknown';
        document.getElementById('deploy-server-version').textContent = revisionData.serverVersion || 'unknown';
        document.getElementById('deploy-pubkey').textContent =
            keyData.pubkey || ('Error: ' + keyData.error);

        document.getElementById('kiosk-deploy-list').innerHTML = kiosks.map(k => `
            <div class="kiosk-deploy-card">
                <div class="kiosk-deploy-info">
                    <strong>${escapeHtml(k.name)}</strong>
                    <span class="kiosk-deploy-ip">${escapeHtml(k.user)}@${escapeHtml(k.ip)}</span>
                </div>
                <button class="btn btn-success" onclick="deployOne(${k.id}, '${escapeHtml(k.name)}')">Deploy</button>
            </div>
        `).join('');
    } catch (error) { showMessage('Failed to load deploy info', 'error'); }
}

function copyDeployKey() {
    const key = document.getElementById('deploy-pubkey').textContent;
    navigator.clipboard.writeText(key)
        .then(() => showMessage('Public key copied to clipboard'))
        .catch(() => showMessage('Copy failed — select and copy manually', 'error'));
}

async function deployOne(id, name) {
    appendDeployOutput(`\n--- Deploying to ${name} ---`);
    const btn = document.querySelector(`#kiosk-deploy-list .kiosk-deploy-card:nth-child(${id}) button`);
    try {
        const res = await apiFetch(`${API_URL}/kiosks/${id}/deploy`, { method: 'POST' });
        const data = await res.json();
        if (!res.ok) {
            appendDeployOutput(`ERROR: ${data.error}\n${data.output || ''}`);
            showMessage(`Deploy to ${name} failed`, 'error');
        } else {
            appendDeployOutput(data.output);
            showMessage(`Deploy to ${name} complete`);
        }
    } catch (e) {
        appendDeployOutput(`ERROR: ${e.message}`);
        showMessage(`Deploy to ${name} failed`, 'error');
    }
}

async function deployAll() {
    const allBtn = document.getElementById('deploy-all-btn');
    allBtn.disabled = true;
    appendDeployOutput('\n=== Deploy All ===');
    try {
        const res = await apiFetch(`${API_URL}/kiosks`);
        const kiosks = await res.json();
        for (const k of kiosks) {
            await deployOne(k.id, k.name);
        }
        showMessage('Deploy all complete');
    } finally {
        allBtn.disabled = false;
    }
}

function appendDeployOutput(text) {
    const el = document.getElementById('deploy-output');
    el.textContent += '\n' + text;
    el.scrollTop = el.scrollHeight;
}

document.getElementById('restore-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const file = document.getElementById('restore-file').files[0];
    if (!file) return;
    if (!confirm('This will immediately overwrite all current data. Are you sure?')) return;
    const formData = new FormData();
    formData.append('database', file);
    try {
        const res = await apiFetch(`${API_URL}/restore`, { method: 'POST', body: formData });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || res.status);
        const c = data.db_counts && typeof data.db_counts.companies === 'number' ? data.db_counts.companies : 'unknown';
        const i = data.db_counts && typeof data.db_counts.individuals === 'number' ? data.db_counts.individuals : 'unknown';
        showMessage(`Database restored. Companies: ${c}, Individuals: ${i}`);
        document.getElementById('restore-file').value = '';
    } catch (error) { showMessage('Restore failed: ' + error.message, 'error'); }
});

window.addEventListener('DOMContentLoaded', () => {
    setupAuthUi();
    ensureAuthenticated().then(ok => {
        if (ok) {
            isAuthenticated = true;
            setAuthState(true);
            loadCompanies();
        }
    });
});

window.downloadCsv = downloadCsv;
window.downloadSqlBackup = downloadBackup;

function setupAuthUi() {
    const loginForm = document.getElementById('auth-form');
    const logoutBtn = document.getElementById('logout-btn');
    loginForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const password = document.getElementById('auth-password').value;
        try {
            const res = await apiFetch(`${API_URL}/auth/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ password })
            });
            const data = await res.json();
            if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
            authToken = data.token || '';
            isAuthenticated = true;
            document.getElementById('auth-password').value = '';
            setAuthState(true);
            loadCompanies();
            showMessage('Logged in');
        } catch (err) {
            showMessage('Login failed', 'error');
        }
    });
    logoutBtn.addEventListener('click', async () => {
        try { await apiFetch(`${API_URL}/auth/logout`, { method: 'POST' }); } catch (e) {}
        authToken = '';
        isAuthenticated = false;
        setAuthState(false);
        window.location.href = '/';
    });
    setAuthState(false);
}

function setAuthState(authenticated) {
    document.getElementById('auth-panel').style.display = authenticated ? 'none' : 'block';
    document.getElementById('logout-btn').style.display = authenticated ? 'inline-block' : 'none';
    document.getElementById('tabs-container').style.display = authenticated ? 'block' : 'none';
}

async function ensureAuthenticated() {
    try {
        const res = await apiFetch(`${API_URL}/auth/me`);
        if (!res.ok) return false;
        const data = await res.json();
        const ok = !!data.authenticated;
        if (!ok) authToken = '';
        return ok;
    } catch (e) {
        return false;
    }
}
