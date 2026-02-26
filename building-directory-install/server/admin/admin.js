const API_URL = '/api';

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text ?? '';
    return div.innerHTML;
}

function showTab(btn, tabName) {
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

function showMessage(text, type = 'success') {
    const msg = document.getElementById('message');
    msg.textContent = text;
    msg.className = `message ${type} active`;
    setTimeout(() => msg.classList.remove('active'), 5000);
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
        renderCompanies(await fetch(`${API_URL}/companies`).then(r => r.json()));
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
            renderCompanies(await fetch(url).then(r => r.json()));
        } catch (e) { showMessage('Search failed', 'error'); }
    }, 300);
}

function editCompany(id) {
    fetch(`${API_URL}/companies`).then(r => r.json()).then(companies => {
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
        const individuals = await fetch(`${API_URL}/individuals`).then(r => r.json());
        const linked = individuals.filter(p => p.company_id === id);
        const warning = linked.length > 0
            ? `\n\nWarning: ${linked.length} individual(s) are assigned to this company and will be left without a company.`
            : '';
        if (!confirm(`Delete this company?${warning}`)) return;
        const res = await fetch(`${API_URL}/companies/${id}`, { method: 'DELETE' });
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
        const res = await fetch(id ? `${API_URL}/companies/${id}` : `${API_URL}/companies`, {
            method: id ? 'PUT' : 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        if (!res.ok) throw new Error(res.status);
        showMessage(`Company ${id ? 'updated' : 'created'}`);
        resetCompanyForm(); loadCompanies();
    } catch (error) { showMessage('Failed to save', 'error'); }
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
        renderIndividuals(await fetch(`${API_URL}/individuals`).then(r => r.json()));
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
            renderIndividuals(await fetch(url).then(r => r.json()));
        } catch (e) { showMessage('Search failed', 'error'); }
    }, 300);
}

async function loadCompaniesForDropdown() {
    try {
        const response = await fetch(`${API_URL}/companies`);
        const companies = await response.json();
        document.getElementById('individual-company').innerHTML =
            '<option value="">-- None --</option>' +
            companies.map(c => `<option value="${c.id}">${escapeHtml(c.name)}</option>`).join('');
    } catch (error) { console.error('Failed to load companies'); }
}

function editIndividual(id) {
    fetch(`${API_URL}/individuals`).then(r => r.json()).then(individuals => {
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
        await fetch(`${API_URL}/individuals/${id}`, { method: 'DELETE' });
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
        const res = await fetch(id ? `${API_URL}/individuals/${id}` : `${API_URL}/individuals`, {
            method: id ? 'PUT' : 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        if (!res.ok) throw new Error(res.status);
        showMessage(`Individual ${id ? 'updated' : 'created'}`);
        resetIndividualForm(); loadIndividuals();
    } catch (error) { showMessage('Failed to save', 'error'); }
});

async function loadBuildingInfo() {
    try {
        const response = await fetch(`${API_URL}/building-info`);
        const content = await response.json();
        document.getElementById('building-info-content').value = content;
    } catch (error) { showMessage('Failed to load', 'error'); }
}

document.getElementById('building-info-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
        await fetch(`${API_URL}/building-info`, {
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
            fetch(`${API_URL}/background-image`),
            fetch(`${API_URL}/background-images`)
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
        const res = await fetch(`${API_URL}/background-image`, {
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
        const res = await fetch(`${API_URL}/background-images/${encodeURIComponent(filename)}`, { method: 'DELETE' });
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
        const res = await fetch(`${API_URL}/background-image`, { method: 'POST', body: formData });
        if (!res.ok) throw new Error(res.status);
        showMessage('Image uploaded and set as background');
        document.getElementById('bg-file').value = '';
        loadBackgroundImage();
    } catch (error) { showMessage('Failed to upload image', 'error'); }
});

async function loadDeployTab() {
    try {
        const [kioskRes, urlRes, keyRes] = await Promise.all([
            fetch(`${API_URL}/kiosks`),
            fetch(`${API_URL}/kiosks/server-url`),
            fetch(`${API_URL}/kiosks/deploy-pubkey`)
        ]);
        const kiosks = await kioskRes.json();
        const { url } = await urlRes.json();
        const keyData = await keyRes.json();

        document.getElementById('deploy-server-url').textContent = url;
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
        const res = await fetch(`${API_URL}/kiosks/${id}/deploy`, { method: 'POST' });
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
        const res = await fetch(`${API_URL}/kiosks`);
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
        const res = await fetch(`${API_URL}/restore`, { method: 'POST', body: formData });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || res.status);
        showMessage('Database restored successfully');
        document.getElementById('restore-file').value = '';
    } catch (error) { showMessage('Restore failed: ' + error.message, 'error'); }
});

window.addEventListener('DOMContentLoaded', () => {
    loadCompanies();
});
