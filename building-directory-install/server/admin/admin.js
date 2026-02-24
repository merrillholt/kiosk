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
    
    if (tabName === 'companies') loadCompanies();
    else if (tabName === 'individuals') { loadIndividuals(); loadCompaniesForDropdown(); }
    else if (tabName === 'building-info') loadBuildingInfo();
    else if (tabName === 'appearance') loadBackgroundImage();
}

function showMessage(text, type = 'success') {
    const msg = document.getElementById('message');
    msg.textContent = text;
    msg.className = `message ${type} active`;
    setTimeout(() => msg.classList.remove('active'), 5000);
}

async function loadCompanies() {
    try {
        const response = await fetch(`${API_URL}/companies`);
        const companies = await response.json();
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
    } catch (error) { showMessage('Failed to load companies', 'error'); }
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

async function loadIndividuals() {
    try {
        const response = await fetch(`${API_URL}/individuals`);
        const individuals = await response.json();
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
    } catch (error) { showMessage('Failed to load individuals', 'error'); }
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
        const response = await fetch(`${API_URL}/background-image`);
        const { filename } = await response.json();
        const img = document.getElementById('bg-preview-img');
        const none = document.getElementById('bg-preview-none');
        if (filename) {
            img.src = `/${filename}?v=${Date.now()}`;
            img.style.display = 'block';
            none.style.display = 'none';
        } else {
            img.style.display = 'none';
            none.style.display = '';
        }
    } catch (error) { showMessage('Failed to load background image', 'error'); }
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
        showMessage('Background image updated');
        document.getElementById('bg-file').value = '';
        loadBackgroundImage();
    } catch (error) { showMessage('Failed to upload image', 'error'); }
});

window.addEventListener('DOMContentLoaded', () => loadCompanies());
